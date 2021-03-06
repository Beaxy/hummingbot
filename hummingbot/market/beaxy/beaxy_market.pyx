from hummingbot.core.data_type.limit_order import LimitOrder
from typing import (
    Any,
    Dict,
    List,
    AsyncIterable,
    Optional,
    Coroutine,
    Tuple,
)
import math
import re
import pandas as pd
import logging
from async_timeout import timeout
from decimal import Decimal
from aiohttp.client_exceptions import ContentTypeError
from hummingbot.core.utils.async_utils import (
    safe_ensure_future,
    safe_gather,
)
from libc.stdint cimport int64_t
from hummingbot.core.network_iterator import NetworkStatus
from hummingbot.client.config.fee_overrides_config_map import fee_overrides_config_map
from hummingbot.core.data_type.order_book_tracker import OrderBookTrackerDataSourceType
import json
from hummingbot.market.market_base import (
    MarketBase
)
from hummingbot.core.data_type.order_book cimport OrderBook
from hummingbot.logger import HummingbotLogger
import asyncio
from hummingbot.core.clock cimport Clock
from hummingbot.core.data_type.cancellation_result import CancellationResult

from hummingbot.market.market_base import (
    MarketBase
)
from hummingbot.market.trading_rule cimport TradingRule
from hummingbot.market.beaxy.beaxy_api_order_book_data_source import BeaxyAPIOrderBookDataSource
from hummingbot.market.beaxy.beaxy_constants import BeaxyConstants
from hummingbot.market.beaxy.beaxy_auth import BeaxyAuth
from hummingbot.market.beaxy.beaxy_order_book_tracker import BeaxyOrderBookTracker
from hummingbot.market.beaxy.beaxy_in_flight_order import BeaxyInFlightOrder
from hummingbot.market.beaxy.beaxy_user_stream_tracker import BeaxyUserStreamTracker
from hummingbot.core.event.events import (
    MarketEvent,
    BuyOrderCompletedEvent,
    SellOrderCompletedEvent,
    OrderFilledEvent,
    OrderCancelledEvent,
    BuyOrderCreatedEvent,
    OrderExpiredEvent,
    SellOrderCreatedEvent,
    MarketTransactionFailureEvent,
    MarketOrderFailureEvent,
    OrderType,
    TradeType,
    TradeFee
)
import aiohttp
import conf
from hummingbot.core.utils.tracking_nonce import get_tracking_nonce
from hummingbot.core.utils.estimate_fee import estimate_fee

TRADING_PAIR_SPLITTER = re.compile(r"^(\w+)(BTC|ETH|BXY|USDT|USDC)$")
s_logger = None
s_decimal_0 = Decimal("0.0")

cdef class BeaxyMarketTransactionTracker(TransactionTracker):
    cdef:
        BeaxyMarket _owner

    def __init__(self, owner: BeaxyMarket):
        super().__init__()
        self._owner = owner

    cdef c_did_timeout_tx(self, str tx_id):
        TransactionTracker.c_did_timeout_tx(self, tx_id)
        self._owner.c_did_timeout_tx(tx_id)

cdef class BeaxyMarket(MarketBase):
    MARKET_BUY_ORDER_COMPLETED_EVENT_TAG = MarketEvent.BuyOrderCompleted.value
    MARKET_SELL_ORDER_COMPLETED_EVENT_TAG = MarketEvent.SellOrderCompleted.value
    MARKET_ORDER_CANCELLED_EVENT_TAG = MarketEvent.OrderCancelled.value
    MARKET_ORDER_FAILURE_EVENT_TAG = MarketEvent.OrderFailure.value
    MARKET_ORDER_EXPIRED_EVENT_TAG = MarketEvent.OrderExpired.value
    MARKET_ORDER_FILLED_EVENT_TAG = MarketEvent.OrderFilled.value
    MARKET_BUY_ORDER_CREATED_EVENT_TAG = MarketEvent.BuyOrderCreated.value
    MARKET_SELL_ORDER_CREATED_EVENT_TAG = MarketEvent.SellOrderCreated.value

    API_CALL_TIMEOUT = 60.0
    UPDATE_ORDERS_INTERVAL = 10.0
    UPDATE_FEE_PERCENTAGE_INTERVAL = 60.0

    @classmethod
    def logger(cls) -> HummingbotLogger:
        global s_logger
        if s_logger is None:
            s_logger = logging.getLogger(__name__)
        return s_logger

    def __init__(self,
                 api_key: str,
                 api_secret: str,
                 poll_interval: float = 5.0,    # interval which the class periodically pulls status from the rest API
                 order_book_tracker_data_source_type: OrderBookTrackerDataSourceType =
                 OrderBookTrackerDataSourceType.EXCHANGE_API,
                 trading_pairs: Optional[List[str]] = None,
                 trading_required: bool = True):
        super().__init__()
        self._trading_required = trading_required
        self._beaxy_auth = BeaxyAuth(api_key, api_secret)
        self._order_book_tracker = BeaxyOrderBookTracker(data_source_type=order_book_tracker_data_source_type, trading_pairs=trading_pairs)
        self._user_stream_tracker = BeaxyUserStreamTracker(beaxy_auth=self._beaxy_auth)
        self._ev_loop = asyncio.get_event_loop()
        self._poll_notifier = asyncio.Event()
        self._last_timestamp = 0
        self._last_order_update_timestamp = 0
        self._last_fee_percentage_update_timestamp = 0
        self._poll_interval = poll_interval
        self._in_flight_orders = {}
        self._tx_tracker = BeaxyMarketTransactionTracker(self)
        self._trading_rules = {}
        self._data_source_type = order_book_tracker_data_source_type
        self._status_polling_task = None
        self._user_stream_tracker_task = None
        self._user_stream_event_listener_task = None
        self._trading_rules_polling_task = None
        self._shared_client = None
        self._maker_fee_percentage = 0
        self._taker_fee_percentage = 0

    @staticmethod
    def split_trading_pair(trading_pair: str) -> Optional[Tuple[str, str]]:
        try:
            m = TRADING_PAIR_SPLITTER.match(trading_pair)
            return m.group(1), m.group(2)
        # Exceptions are now logged as warnings in trading pair fetcher
        except Exception as e:
            return None

    @staticmethod
    def convert_from_exchange_trading_pair(exchange_trading_pair: str) -> Optional[str]:
        if BeaxyMarket.split_trading_pair(exchange_trading_pair) is None:
            return None
        base_asset, quote_asset = BeaxyMarket.split_trading_pair(exchange_trading_pair)
        return f"{base_asset}-{quote_asset}"

    @staticmethod
    def convert_to_exchange_trading_pair(hb_trading_pair: str) -> str:
        return hb_trading_pair.replace("-", "")

    @property
    def name(self) -> str:
        """
        *required
        :return: A lowercase name / id for the market. Must stay consistent with market name in global settings.
        """
        return "beaxy"

    @property
    def order_books(self) -> Dict[str, OrderBook]:
        """
        *required
        Get mapping of all the order books that are being tracked.
        :return: Dict[trading_pair : OrderBook]
        """
        return self._order_book_tracker.order_books

    @property
    def beaxy_auth(self) -> BeaxyAuth:
        """
        :return: BeaxyAuth class
        """
        return self._beaxy_auth

    @property
    def trading_rules(self) -> Dict[str, Any]:
        return self._trading_rules

    @property
    def status_dict(self) -> Dict[str, bool]:
        """
        *required
        :return: a dictionary of relevant status checks.
        This is used by `ready` method below to determine if a market is ready for trading.
        """
        return {
            "order_books_initialized": self._order_book_tracker.ready,
            "account_balance": len(self._account_balances) > 0 if self._trading_required else True,
            "trading_rule_initialized": len(self._trading_rules) > 0 if self._trading_required else True
        }

    @property
    def ready(self) -> bool:
        """
        *required
        :return: a boolean value that indicates if the market is ready for trading
        """
        return all(self.status_dict.values())

    @property
    def limit_orders(self) -> List[LimitOrder]:
        """
        *required
        :return: list of active limit orders
        """
        return [
            in_flight_order.to_limit_order()
            for in_flight_order in self._in_flight_orders.values()
        ]

    @property
    def tracking_states(self) -> Dict[str, any]:
        """
        *required
        :return: Dict[client_order_id: InFlightOrder]
        This is used by the MarketsRecorder class to orchestrate market classes at a higher level.
        """
        return {
            key: value.to_json()
            for key, value in self._in_flight_orders.items()
        }

    def restore_tracking_states(self, saved_states: Dict[str, any]):
        """
        *required
        Updates inflight order statuses from API results
        This is used by the MarketsRecorder class to orchestrate market classes at a higher level.
        """
        self._in_flight_orders.update({
            key: BeaxyInFlightOrder.from_json(value)
            for key, value in saved_states.items()
        })

    async def get_active_exchange_markets(self) -> pd.DataFrame:
        """
        *required
        Used by the discovery strategy to read order books of all actively trading markets,
        and find opportunities to profit
        """
        return await BeaxyAPIOrderBookDataSource.get_active_exchange_markets()

    cdef c_start(self, Clock clock, double timestamp):
        """
        *required
        c_start function used by top level Clock to orchestrate components of the bot
        """
        self._tx_tracker.c_start(clock, timestamp)
        MarketBase.c_start(self, clock, timestamp)

    async def start_network(self):
        """
        *required
        Async function used by NetworkBase class to handle when a single market goes online
        """
        self.logger().debug(f"Starting beaxy network. Trading required is {self._trading_required}")
        self._stop_network()
        self._order_book_tracker.start()
        self.logger().debug(f"OrderBookTracker started, starting polling tasks.")
        if self._trading_required:
            self._status_polling_task = safe_ensure_future(self._status_polling_loop())
            self._trading_rules_polling_task = safe_ensure_future(self._trading_rules_polling_loop())
            self._user_stream_tracker_task = safe_ensure_future(self._user_stream_tracker.start())
            self._user_stream_event_listener_task = safe_ensure_future(self._user_stream_event_listener())

    async def check_network(self) -> NetworkStatus:
        try:
            res = await self._api_request(http_method="GET", path_url=BeaxyConstants.TradingApi.HEALTH_ENDPOINT, is_auth_required=False)
            if not res["is_alive"]:
                return NetworkStatus.STOPPED
        except asyncio.CancelledError:
            raise
        except Exception:
            self.logger().network(f"Error fetching Beaxy network status.", exc_info=True)
            return NetworkStatus.NOT_CONNECTED
        return NetworkStatus.CONNECTED

    cdef c_tick(self, double timestamp):
        """
        *required
        Used by top level Clock to orchestrate components of the bot.
        This function is called frequently with every clock tick
        """
        cdef:
            int64_t last_tick = <int64_t>(self._last_timestamp / self._poll_interval)
            int64_t current_tick = <int64_t>(timestamp / self._poll_interval)

        MarketBase.c_tick(self, timestamp)
        if current_tick > last_tick:
            if not self._poll_notifier.is_set():
                self._poll_notifier.set()
        self._last_timestamp = timestamp

    def _stop_network(self):
        """
        Synchronous function that handles when a single market goes offline
        """
        self._order_book_tracker.stop()
        if self._status_polling_task is not None:
            self._status_polling_task.cancel()
        if self._user_stream_tracker_task is not None:
            self._user_stream_tracker_task.cancel()
        if self._user_stream_event_listener_task is not None:
            self._user_stream_event_listener_task.cancel()
        if self._trading_rules_polling_task is not None:
            self._trading_rules_polling_task.cancel()
        self._status_polling_task = self._user_stream_tracker_task = \
            self._user_stream_event_listener_task = None

    async def list_orders(self) -> List[Any]:
        """
        Gets a list of the user's active orders via rest API
        :returns: json response
        """
        path_url = BeaxyConstants.TradingApi.ORDERS_ENDPOINT
        result = await self._api_request("get", path_url=path_url)
        return result

    async def _update_order_status(self):
        """
        Pulls the rest API for for latest order statuses and update local order statuses.
        """
        cdef:
            double current_timestamp = self._current_timestamp

        if current_timestamp - self._last_order_update_timestamp <= self.UPDATE_ORDERS_INTERVAL:
            return

        tracked_orders = list(self._in_flight_orders.values())
        results = await self.list_orders()
        order_dict = dict((result["id"], result) for result in results)

        for tracked_order in tracked_orders:
            exchange_order_id = await tracked_order.get_exchange_order_id()
            order_update = order_dict.get(exchange_order_id)
            client_order_id = tracked_order.client_order_id
            if order_update is None:
                self.logger().info(
                    f"The tracked order {client_order_id} does not exist on Beaxy."
                    f"Removing from tracking."
                )
                self.c_stop_tracking_order(client_order_id)
                self.c_trigger_event(
                    self.MARKET_ORDER_CANCELLED_EVENT_TAG,
                    OrderCancelledEvent(self._current_timestamp, client_order_id)
                )
                continue

            # Calculate the newly executed amount for this update.
            new_confirmed_amount = Decimal(order_update["cumulative_quantity"])
            execute_amount_diff = new_confirmed_amount - tracked_order.executed_amount_base
            execute_price = Decimal(order_update["average_price"])

            order_type_description = tracked_order.order_type_description
            order_type = OrderType.MARKET if tracked_order.order_type == OrderType.MARKET else OrderType.LIMIT
            # Emit event if executed amount is greater than 0.
            if execute_amount_diff > s_decimal_0:
                order_filled_event = OrderFilledEvent(
                    self._current_timestamp,
                    tracked_order.client_order_id,
                    tracked_order.trading_pair,
                    tracked_order.trade_type,
                    order_type,
                    execute_price,
                    execute_amount_diff,
                    self.c_get_fee(
                        tracked_order.base_asset,
                        tracked_order.quote_asset,
                        order_type,
                        tracked_order.trade_type,
                        execute_price,
                        execute_amount_diff,
                    ),
                    exchange_trade_id=exchange_order_id,
                )
                self.logger().info(f"Filled {execute_amount_diff} out of {tracked_order.amount} of the "
                                   f"{order_type_description} order {client_order_id}.")
                self.c_trigger_event(self.MARKET_ORDER_FILLED_EVENT_TAG, order_filled_event)

            # Update the tracked order
            tracked_order.last_state = order_update["status"]
            tracked_order.executed_amount_base = new_confirmed_amount
            tracked_order.executed_amount_quote = new_confirmed_amount * execute_price
            if tracked_order.is_done:
                if not tracked_order.is_failure:
                    if tracked_order.trade_type == TradeType.BUY:
                        self.logger().info(f"The market buy order {tracked_order.client_order_id} has completed "
                                           f"according to order status API.")
                        self.c_trigger_event(self.MARKET_BUY_ORDER_COMPLETED_EVENT_TAG,
                                             BuyOrderCompletedEvent(self._current_timestamp,
                                                                    tracked_order.client_order_id,
                                                                    tracked_order.base_asset,
                                                                    tracked_order.quote_asset,
                                                                    (tracked_order.fee_asset
                                                                     or tracked_order.base_asset),
                                                                    tracked_order.executed_amount_base,
                                                                    tracked_order.executed_amount_quote,
                                                                    tracked_order.fee_paid,
                                                                    order_type))
                    else:
                        self.logger().info(f"The market sell order {tracked_order.client_order_id} has completed "
                                           f"according to order status API.")
                        self.c_trigger_event(self.MARKET_SELL_ORDER_COMPLETED_EVENT_TAG,
                                             SellOrderCompletedEvent(self._current_timestamp,
                                                                     tracked_order.client_order_id,
                                                                     tracked_order.base_asset,
                                                                     tracked_order.quote_asset,
                                                                     (tracked_order.fee_asset
                                                                      or tracked_order.quote_asset),
                                                                     tracked_order.executed_amount_base,
                                                                     tracked_order.executed_amount_quote,
                                                                     tracked_order.fee_paid,
                                                                     order_type))
                else:
                    self.logger().info(f"The market order {tracked_order.client_order_id} has failed/been cancelled "
                                       f"according to order status API.")
                    self.c_trigger_event(self.MARKET_ORDER_CANCELLED_EVENT_TAG,
                                         OrderCancelledEvent(
                                             self._current_timestamp,
                                             tracked_order.client_order_id
                                         ))
                self.c_stop_tracking_order(tracked_order.client_order_id)
        self._last_order_update_timestamp = current_timestamp

    async def place_order(self, order_id: str, trading_pair: str, amount: Decimal, is_buy: bool, order_type: OrderType,
                          price: Decimal):
        """
        Async wrapper for placing orders through the rest API.
        :returns: json response from the API
        """
        path_url = BeaxyConstants.TradingApi.ORDERS_ENDPOINT
        data = {
            # Putting client order id in text because API requires client order id to be a valid UUID
            "text": order_id,
            "security_id": trading_pair,
            "type": "limit" if order_type is OrderType.LIMIT else "market",
            "side": "buy" if is_buy else "sell",
            "quantity": f"{amount:f}",
            "time_in_force": "gtc",  # Good till cancelled https://beaxyapiv2trading.docs.apiary.io/#/data-structures/0/time-in-force?mc=reference%2Frest%2Forder%2Fcreate-order%2F200
            "destination": "MAXI",
        }
        if order_type is OrderType.LIMIT:
            data["price"] = f"{price:f}"
        order_result = await self._api_request("POST", path_url=path_url, data=data)
        self.logger().debug(f"Set order result {order_result}")
        return order_result

    cdef object c_get_fee(self,
                          str base_currency,
                          str quote_currency,
                          object order_type,
                          object order_side,
                          object amount,
                          object price):
        """
        *required
        function to calculate fees for a particular order
        :returns: TradeFee class that includes fee percentage and flat fees
        """
        # There is no API for checking user's fee tier
        """
        cdef:
            object maker_fee = self._maker_fee_percentage
            object taker_fee = self._taker_fee_percentage
        if order_type is OrderType.LIMIT and fee_overrides_config_map["beaxy_maker_fee"].value is not None:
            return TradeFee(percent=fee_overrides_config_map["beaxy_maker_fee"].value / Decimal("100"))
        if order_type is OrderType.MARKET and fee_overrides_config_map["beaxy_taker_fee"].value is not None:
            return TradeFee(percent=fee_overrides_config_map["beaxy_taker_fee"].value / Decimal("100"))
        """

        is_maker = order_type is OrderType.LIMIT
        return estimate_fee("beaxy", is_maker)

    async def execute_buy(self,
                          order_id: str,
                          trading_pair: str,
                          amount: Decimal,
                          order_type: OrderType,
                          price: Optional[Decimal] = s_decimal_0):
        """
        Function that takes strategy inputs, auto corrects itself with trading rule,
        and submit an API request to place a buy order
        """
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]

        decimal_amount = self.quantize_order_amount(trading_pair, amount)
        decimal_price = self.quantize_order_price(trading_pair, price)
        if decimal_amount < trading_rule.min_order_size:
            raise ValueError(f"Buy order amount {decimal_amount} is lower than the minimum order size "
                             f"{trading_rule.min_order_size}.")

        try:
            self.c_start_tracking_order(order_id, trading_pair, order_type, TradeType.BUY, decimal_price, decimal_amount)
            order_result = await self.place_order(order_id, trading_pair, decimal_amount, True, order_type, decimal_price)
            exchange_order_id = order_result["id"]
            tracked_order = self._in_flight_orders.get(order_id)
            if tracked_order is not None:
                self.logger().info(f"Created {order_type} buy order {order_id} for {decimal_amount} {trading_pair}.")
                tracked_order.update_exchange_order_id(exchange_order_id)

            self.c_trigger_event(self.MARKET_BUY_ORDER_CREATED_EVENT_TAG,
                                 BuyOrderCreatedEvent(self._current_timestamp,
                                                      order_type,
                                                      trading_pair,
                                                      decimal_amount,
                                                      decimal_price,
                                                      order_id))
        except asyncio.CancelledError:
            raise
        except Exception:
            self.c_stop_tracking_order(order_id)
            order_type_str = "MARKET" if order_type == OrderType.MARKET else "LIMIT"
            self.logger().network(
                f"Error submitting buy {order_type_str} order to Beaxy for "
                f"{decimal_amount} {trading_pair} {price}.",
                exc_info=True,
                app_warning_msg=f"Failed to submit buy order to Beaxy."
                                "Check API key and network connection."
            )
            self.c_trigger_event(self.MARKET_ORDER_FAILURE_EVENT_TAG,
                                 MarketOrderFailureEvent(self._current_timestamp, order_id, order_type))

    cdef str c_buy(self, str trading_pair, object amount, object order_type=OrderType.MARKET, object price=s_decimal_0,
                   dict kwargs={}):
        """
        *required
        Synchronous wrapper that generates a client-side order ID and schedules the buy order.
        """
        cdef:
            int64_t tracking_nonce = <int64_t> get_tracking_nonce()
            str order_id = str(f"buy-{trading_pair}-{tracking_nonce}")

        safe_ensure_future(self.execute_buy(order_id, trading_pair, amount, order_type, price))
        return order_id

    async def execute_sell(self,
                           order_id: str,
                           trading_pair: str,
                           amount: Decimal,
                           order_type: OrderType,
                           price: Optional[Decimal] = s_decimal_0):
        """
        Function that takes strategy inputs, auto corrects itself with trading rule,
        and submit an API request to place a sell order
        """
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]

        decimal_amount = self.quantize_order_amount(trading_pair, amount)
        decimal_price = self.quantize_order_price(trading_pair, price)
        if decimal_amount < trading_rule.min_order_size:
            raise ValueError(f"Sell order amount {decimal_amount} is lower than the minimum order size "
                             f"{trading_rule.min_order_size}.")

        try:
            self.c_start_tracking_order(order_id, trading_pair, order_type, TradeType.SELL, decimal_price, decimal_amount)
            order_result = await self.place_order(order_id, trading_pair, decimal_amount, False, order_type, decimal_price)

            exchange_order_id = order_result["id"]
            tracked_order = self._in_flight_orders.get(order_id)
            if tracked_order is not None:
                self.logger().info(f"Created {order_type} sell order {order_id} for {decimal_amount} {trading_pair}.")
                tracked_order.update_exchange_order_id(exchange_order_id)

            self.c_trigger_event(self.MARKET_SELL_ORDER_CREATED_EVENT_TAG,
                                 SellOrderCreatedEvent(self._current_timestamp,
                                                       order_type,
                                                       trading_pair,
                                                       decimal_amount,
                                                       decimal_price,
                                                       order_id))
        except asyncio.CancelledError:
            raise
        except Exception:
            self.c_stop_tracking_order(order_id)
            order_type_str = "MARKET" if order_type == OrderType.MARKET else "LIMIT"
            self.logger().network(
                f"Error submitting sell {order_type_str} order to Beaxy for "
                f"{decimal_amount} {trading_pair} {price}.",
                exc_info=True,
                app_warning_msg="Failed to submit sell order to Beaxy. "
                                "Check API key and network connection."
            )
            self.c_trigger_event(self.MARKET_ORDER_FAILURE_EVENT_TAG,
                                 MarketOrderFailureEvent(self._current_timestamp, order_id, order_type))

    cdef str c_sell(self,
                    str trading_pair,
                    object amount,
                    object order_type=OrderType.MARKET,
                    object price=s_decimal_0,
                    dict kwargs={}):
        """
        *required
        Synchronous wrapper that generates a client-side order ID and schedules the sell order.
        """
        cdef:
            int64_t tracking_nonce = <int64_t> get_tracking_nonce()
            str order_id = str(f"sell-{trading_pair}-{tracking_nonce}")
        safe_ensure_future(self.execute_sell(order_id, trading_pair, amount, order_type, price))
        return order_id

    async def execute_cancel(self, trading_pair: str, order_id: str):
        """
        Function that makes API request to cancel an active order
        """
        try:
            tracked_order = self._in_flight_orders.get(order_id)
            if tracked_order is None:
                raise ValueError(f"Failed to cancel order - {order_id}. Order not found.")
            path_url = BeaxyConstants.TradingApi.ORDERS_ENDPOINT
            cancel_result = await self._api_request("delete", path_url=path_url, custom_headers={"X-Deltix-Order-ID": tracked_order.exchange_order_id.lower()})
            return order_id
        except asyncio.CancelledError:
            raise
        except IOError as ioe:
            self.logger().warning(ioe)
        except Exception as e:
            self.logger().network(
                f"Failed to cancel order {order_id}: ",
                exc_info=True,
                app_warning_msg=f"Failed to cancel the order {order_id} on Beaxy. "
                                f"Check API key and network connection."
            )
        return None

    cdef c_cancel(self, str trading_pair, str order_id):
        """
        *required
        Synchronous wrapper that schedules cancelling an order.
        """
        safe_ensure_future(self.execute_cancel(trading_pair, order_id))
        return order_id

    async def cancel_all(self, timeout_seconds: float) -> List[CancellationResult]:
        """
        *required
        Async function that cancels all active orders.
        Used by bot's top level stop and exit commands (cancelling outstanding orders on exit)
        :returns: List of CancellationResult which indicates whether each order is successfully cancelled.
        """
        incomplete_orders = [o for o in self._in_flight_orders.values() if not o.is_done]
        tasks = [self.execute_cancel(o.trading_pair, o.client_order_id) for o in incomplete_orders]
        order_id_set = set([o.client_order_id for o in incomplete_orders])
        successful_cancellations = []

        try:
            async with timeout(timeout_seconds):
                results = await safe_gather(*tasks, return_exceptions=True)
                for client_order_id in results:
                    if type(client_order_id) is str:
                        order_id_set.remove(client_order_id)
                        successful_cancellations.append(CancellationResult(client_order_id, True))
                    else:
                        self.logger().warning(
                            f"failed to cancel order with error: "
                            f"{repr(client_order_id)}"
                        )
        except Exception as e:
            self.logger().network(
                f"Unexpected error cancelling orders.",
                exc_info=True,
                app_warning_msg="Failed to cancel order on Coinbase Pro. Check API key and network connection."
            )

        failed_cancellations = [CancellationResult(oid, False) for oid in order_id_set]
        return successful_cancellations + failed_cancellations

    async def _update_trade_fees(self):

        cdef:
            double current_timestamp = self._current_timestamp

        if current_timestamp - self._last_fee_percentage_update_timestamp <= self.UPDATE_FEE_PERCENTAGE_INTERVAL:
            return

        try:
            res = await self._api_request("get", BeaxyConstants.TradingApi.SECURITIES_ENDPOINT)
            first_security = res[0]
            self._maker_fee_percentage = Decimal(first_security["buyer_maker_commission_progressive"])
            self._taker_fee_percentage = Decimal(first_security["buyer_taker_commission_progressive"])
            self._last_fee_percentage_update_timestamp = current_timestamp
        except asyncio.CancelledError:
            self.logger().warning("Got cancelled error fetching beaxy fees.")
            raise
        except Exception:
            self.logger().network("Error fetching Beaxy trade fees.", exc_info=True,
                                  app_warning_msg=f"Could not fetch Beaxy trading fees. "
                                  f"Check network connection.")
            raise

    async def _update_balances(self):
        self.logger().debug("Trying to fetch beaxy balances")

        cdef:
            dict new_available_balances = {}
            dict new_balances = {}
            str asset_name
            object balance
        try:
            data = await self._api_request("get", path_url=BeaxyConstants.TradingApi.ACOUNTS_ENDPOINT)

            if data:
                for balance_entry in data:
                    asset_name = balance_entry["currency_id"]
                    balance = Decimal(balance_entry["balance"])
                    new_balances[asset_name] = balance
                    new_available_balances[asset_name] = Decimal(balance_entry["available_for_trading"])

                self._account_available_balances.clear()
                self._account_available_balances = new_available_balances
                self._account_balances.clear()
                self._account_balances = new_balances

        except asyncio.CancelledError:
            raise
        except Exception:
            self.logger().network("Error fetching Beaxy balance updates.", exc_info=True,
                                  app_warning_msg=f"Could not fetch Beaxy balance updates. "
                                  f"Check network connection.")
            raise

    async def _update_trading_rules(self):
        """
        Pulls the API for trading rules (min / max order size, etc)
        """
        cdef:
            int64_t last_tick = <int64_t>(self._last_timestamp / 60.0)
            int64_t current_tick = <int64_t>(self._current_timestamp / 60.0)

        try:
            if current_tick > last_tick or len(self._trading_rules) <= 0:
                product_info = await self._api_request(http_method="get", url=BeaxyConstants.PublicApi.SYMBOLS_URL, is_auth_required=False)
                trading_rules_list = self._format_trading_rules(product_info)
                self._trading_rules.clear()
                for trading_rule in trading_rules_list:
                    self._trading_rules[trading_rule.trading_pair] = trading_rule
        except Exception:
            self.logger().warning(f"Got exception while updating trading rules.", exc_info=True)

    def _format_trading_rules(self, raw_trading_rules: List[Any]) -> List[TradingRule]:
        """
        Turns json data from API into TradingRule instances
        :returns: List of TradingRule
        """
        cdef:
            list retval = []
        for rule in raw_trading_rules:
            try:
                trading_pair = rule.get("symbol")
                # Parsing from string doesn't mess up the precision
                retval.append(TradingRule(trading_pair,
                                          min_price_increment=Decimal(str(rule.get("tickSize"))),
                                          min_order_size=Decimal(str(rule.get("minimumQuantity"))),
                                          max_order_size=Decimal(str(rule.get("maximumQuantity"))),
                                          min_base_amount_increment=Decimal(str(rule.get("quantityIncrement"))),
                                          min_quote_amount_increment=Decimal(str(rule.get("quantityIncrement"))),
                                          max_price_significant_digits=Decimal(str(rule.get("pricePrecision")))))
            except Exception:
                self.logger().error(f"Error parsing the trading_pair rule {rule}. Skipping.", exc_info=True)
        return retval

    async def _iter_user_event_queue(self) -> AsyncIterable[Dict[str, Any]]:
        while True:
            try:
                yield await self._user_stream_tracker.user_stream.get()
            except asyncio.CancelledError:
                raise
            except Exception:
                self.logger().network(
                    "Unknown error. Retrying after 1 seconds.",
                    exc_info=True,
                    app_warning_msg="Could not fetch user events from Beaxy. Check API key and network connection."
                )
                await asyncio.sleep(1.0)

    async def _user_stream_event_listener(self):
        async for event_message in self._iter_user_event_queue():
            try:
                order = event_message["order"]
                exchange_order_id = order["id"]
                client_order_id = order["text"]
                order_status = order['status']

                if client_order_id is None:
                    continue

                tracked_order = self._in_flight_orders.get(client_order_id)

                if tracked_order is None:
                    self.logger().debug(f"Didn't find order with id {client_order_id}")
                    continue

                execute_price = s_decimal_0
                execute_amount_diff = s_decimal_0

                if event_message["events"]:
                    order_event = event_message["events"][0]
                    event_type = order_event["type"]

                    if event_type == 'trade':
                        execute_price = Decimal(order_event.get("trade_price", 0.0))
                        execute_amount_diff = Decimal(order_event.get("trade_quantity", 0.0))
                        tracked_order.executed_amount_base = order["cumulative_quantity"]
                        tracked_order.executed_amount_quote += execute_amount_diff * execute_price

                    if execute_amount_diff > s_decimal_0:
                        self.logger().info(f"Filled {execute_amount_diff} out of {tracked_order.amount} of the "
                                           f"{tracked_order.order_type_description} order {tracked_order.client_order_id}")
                        exchange_order_id = tracked_order.exchange_order_id

                        self.c_trigger_event(self.MARKET_ORDER_FILLED_EVENT_TAG,
                                             OrderFilledEvent(
                                                 self._current_timestamp,
                                                 tracked_order.client_order_id,
                                                 tracked_order.trading_pair,
                                                 tracked_order.trade_type,
                                                 tracked_order.order_type,
                                                 execute_price,
                                                 execute_amount_diff,
                                                 self.c_get_fee(
                                                     tracked_order.base_asset,
                                                     tracked_order.quote_asset,
                                                     tracked_order.order_type,
                                                     tracked_order.trade_type,
                                                     execute_price,
                                                     execute_amount_diff,
                                                 ),
                                                 exchange_trade_id=exchange_order_id
                                             ))

                if order_status == "completely_filled":
                    if tracked_order.trade_type == TradeType.BUY:
                        self.logger().info(f"The market buy order {tracked_order.client_order_id} has completed "
                                           f"according to Beaxy user stream.")
                        self.c_trigger_event(self.MARKET_BUY_ORDER_COMPLETED_EVENT_TAG,
                                             BuyOrderCompletedEvent(self._current_timestamp,
                                                                    tracked_order.client_order_id,
                                                                    tracked_order.base_asset,
                                                                    tracked_order.quote_asset,
                                                                    (tracked_order.fee_asset
                                                                     or tracked_order.base_asset),
                                                                    tracked_order.executed_amount_base,
                                                                    tracked_order.executed_amount_quote,
                                                                    tracked_order.fee_paid,
                                                                    tracked_order.order_type))
                    else:
                        self.logger().info(f"The market sell order {tracked_order.client_order_id} has completed "
                                           f"according to Beaxy user stream.")
                        self.c_trigger_event(self.MARKET_SELL_ORDER_COMPLETED_EVENT_TAG,
                                             SellOrderCompletedEvent(self._current_timestamp,
                                                                     tracked_order.client_order_id,
                                                                     tracked_order.base_asset,
                                                                     tracked_order.quote_asset,
                                                                     (tracked_order.fee_asset
                                                                      or tracked_order.quote_asset),
                                                                     tracked_order.executed_amount_base,
                                                                     tracked_order.executed_amount_quote,
                                                                     tracked_order.fee_paid,
                                                                     tracked_order.order_type))

                    self.c_stop_tracking_order(tracked_order.client_order_id)

                elif order_status == "canceled":
                    tracked_order.last_state = "canceled"
                    self.c_trigger_event(self.MARKET_ORDER_CANCELLED_EVENT_TAG,
                                         OrderCancelledEvent(self._current_timestamp, tracked_order.client_order_id))
                    self.c_stop_tracking_order(tracked_order.client_order_id)
                elif order_status in ["rejected", "replaced", "suspended"]:
                    tracked_order.last_state = order_status
                    self.c_trigger_event(self.MARKET_ORDER_FAILURE_EVENT_TAG,
                                         MarketOrderFailureEvent(self._current_timestamp, tracked_order.client_order_id, tracked_order.order_type))
                    self.c_stop_tracking_order(tracked_order.client_order_id)
                elif order_status == "expired":
                    tracked_order.last_state = "expired"
                    self.c_trigger_event(self.MARKET_ORDER_EXPIRED_EVENT_TAG,
                                         OrderExpiredEvent(self._current_timestamp, tracked_order.client_order_id))
                    self.c_stop_tracking_order(tracked_order.client_order_id)

            except Exception:
                self.logger().error("Unexpected error in user stream listener loop.", exc_info=True)
                await asyncio.sleep(5.0)

    async def _http_client(self) -> aiohttp.ClientSession:
        """
        :returns: Shared client session instance
        """
        if self._shared_client is None:
            self._shared_client = aiohttp.ClientSession()
        return self._shared_client

    async def _api_request(self,
                           http_method: str,
                           path_url: str = None,
                           url: str = None,
                           is_auth_required: bool = True,
                           data: Optional[Dict[str, Any]] = None,
                           custom_headers: [Optional[Dict[str, str]]] = None) -> Dict[str, Any]:
        """
        A wrapper for submitting API requests to Beaxy
        :returns: json data from the endpoints
        """
        try:
            assert path_url is not None or url is not None

            url = f"{BeaxyConstants.TradingApi.BASE_URL}{path_url}" if url is None else url
            data_str = "" if data is None else json.dumps(data, separators=(',', ':'))

            if is_auth_required:
                headers = await self.beaxy_auth.generate_auth_dict(http_method, path_url, data_str)
            else:
                headers = {"Content-Type": "application/json"}

            if custom_headers:
                headers = {**custom_headers, **headers}

            if http_method.upper() == "POST":
                headers["Content-Type"] = "application/json; charset=utf-8"

            self.logger().debug(f"Submitting {http_method} request to {url} with headers {headers}")

            client = await self._http_client()
            async with client.request(http_method.upper(), url=url, timeout=self.API_CALL_TIMEOUT, data=data_str, headers=headers) as response:
                result = None
                if response.status != 200:
                    raise IOError(f"Error during api request with body {data_str}. HTTP status is {response.status}. Response - {await response.text()} - Request {response.request_info}")
                try:
                    result = await response.json()
                except ContentTypeError:
                    pass

                self.logger().debug(f"Got response status {response.status}")
                return result
        except Exception:
            self.logger().warning(f"Exception while making api request.", exc_info=True)
            raise

    async def _status_polling_loop(self):
        """
        Background process that periodically pulls for changes from the rest API
        """
        while True:
            try:

                self._poll_notifier = asyncio.Event()
                await self._poll_notifier.wait()
                await safe_gather(self._update_balances())
                await asyncio.sleep(60)
                await safe_gather(self._update_trade_fees())
                await asyncio.sleep(60)
                await safe_gather(self._update_order_status())
            except asyncio.CancelledError:
                raise
            except Exception:
                self.logger().network(
                    "Unexpected error while fetching account updates.",
                    exc_info=True,
                    app_warning_msg=f"Could not fetch account updates on Beaxy."
                                    f"Check API key and network connection."
                )
                await asyncio.sleep(0.5)

    async def _trading_rules_polling_loop(self):
        """
        Separate background process that periodically pulls for trading rule changes
        (Since trading rules don't get updated often, it is pulled less often.)
        """
        while True:
            try:
                await safe_gather(self._update_trading_rules())
                await asyncio.sleep(6000)
            except asyncio.CancelledError:
                raise
            except Exception:
                self.logger().network(
                    "Unexpected error while fetching trading rules.",
                    exc_info=True,
                    app_warning_msg=f"Could not fetch trading rule updates on Beaxy. "
                                    f"Check network connection."
                )
                await asyncio.sleep(0.5)

    cdef OrderBook c_get_order_book(self, str trading_pair):
        """
        :returns: OrderBook for a specific trading pair
        """
        cdef:
            dict order_books = self._order_book_tracker.order_books

        if trading_pair not in order_books:
            raise ValueError(f"No order book exists for '{trading_pair}'.")
        return order_books[trading_pair]

    cdef c_start_tracking_order(self,
                                str client_order_id,
                                str trading_pair,
                                object order_type,
                                object trade_type,
                                object price,
                                object amount):
        """
        Add new order to self._in_flight_orders mapping
        """
        self._in_flight_orders[client_order_id] = BeaxyInFlightOrder(
            client_order_id,
            None,
            trading_pair,
            order_type,
            trade_type,
            price,
            amount,
        )

    cdef c_did_timeout_tx(self, str tracking_id):
        self.c_trigger_event(self.MARKET_TRANSACTION_FAILURE_EVENT_TAG,
                             MarketTransactionFailureEvent(self._current_timestamp, tracking_id))

    cdef object c_get_order_price_quantum(self, str trading_pair, object price):
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]

        return trading_rule.min_price_increment

    cdef object c_get_order_size_quantum(self, str trading_pair, object order_size):
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]
        return Decimal(trading_rule.min_base_amount_increment)

    cdef object c_quantize_order_amount(self, str trading_pair, object amount, object price=s_decimal_0):
        """
        *required
        Check current order amount against trading rule, and correct any rule violations
        :return: Valid order amount in Decimal format
        """
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]
            object quantized_amount = MarketBase.c_quantize_order_amount(self, trading_pair, amount)

        # Check against min_order_size. If not passing either check, return 0.
        if quantized_amount < trading_rule.min_order_size:
            return s_decimal_0

        # Check against max_order_size. If not passing either check, return 0.
        if quantized_amount > trading_rule.max_order_size:
            return s_decimal_0

        return quantized_amount

    cdef c_stop_tracking_order(self, str order_id):
        """
        Delete an order from self._in_flight_orders mapping
        """
        if order_id in self._in_flight_orders:
            del self._in_flight_orders[order_id]
