{- |
Module      : GeniusYield.OrderBot.Types
Copyright   : (c) 2024 GYELD GMBH
License     : Apache 2.0
Maintainer  : support@geniusyield.co
Stability   : develop
-}
module GeniusYield.OrderBot.Types (
  OrderInfo (OrderInfo, orderRef, orderType, assetInfo, volume, price, poi),
  SomeOrderInfo (SomeOrderInfo),
  OrderAssetPair (currencyAsset, commodityAsset),
  OrderType (..),
  SOrderType (..),
  Volume (volumeMin, volumeMax),
  Price (..),
  mkOrderInfo,
  isSellOrder,
  isBuyOrder,
  mkOrderAssetPair,
  equivalentAssetPair,
  mkEquivalentAssetPair,
  invPrice,
  TokenDisplayDetails (..),
  adaTokenDisplayDetails,
  DexPair (..),
) where

import Data.Aeson (ToJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Kind (Type)
import Data.Ratio (denominator, numerator, (%))
import Data.Word (Word64)
import GeniusYield.Api.Dex.PartialOrder (PartialOrderInfo (..))
import GeniusYield.Imports (Text)
import GeniusYield.Types (rationalToGHC)
import GeniusYield.Types.TxOutRef (GYTxOutRef)
import GeniusYield.Types.Value (GYAssetClass (..))
import Numeric.Natural (Natural)

-------------------------------------------------------------------------------
-- Information on DEX orders relevant to a matching strategy
-------------------------------------------------------------------------------

{- | For each unique 'OrderAssetPair' (see: 'equivalentAssetPair'): there are 2
'OrderInfo' types: 'OrderInfo BuyOrder', and 'OrderInfo SellOrder'.

For a buy order, the volume indicates the amount of 'commodityAsset' being bought. Whereas
the price indicates the requested price, in 'currencyAsset', of each 'commodityAsset' being bought.

For a sell order, the volume indicates the amount of 'commodityAsset' being sold. Whereas
the price indicates the requested price, in 'currencyAsset', for each 'commodityAsset' being sold.

See: 'mkOrderInfo'.
-}
type OrderInfo ∷ OrderType → Type
data OrderInfo t = OrderInfo
  { orderRef ∷ GYTxOutRef,
    orderType ∷ SOrderType t,
    assetInfo ∷ OrderAssetPair,
    -- | Volume of the 'commodityAsset', either being bought or sold.
    volume ∷ Volume,
    -- | Price of each 'commodityAsset', in 'currencyAsset'.
    price ∷ Price,
    -- | The complete PartialOrderInfo. To avoid querying it again when filling the order
    poi ∷ PartialOrderInfo
  }
  deriving stock (Eq, Show)

-- | Existential that can encapsulate both buy and sell orders.
data SomeOrderInfo = ∀ t. SomeOrderInfo (OrderInfo t)

deriving stock instance Show SomeOrderInfo

-- Q: Should owner key, owner addr, and timestamp be part of this?

{- | Given a partialOrderInfo from a DEX order on the chain, and the
OrderAssetPair that determines the commodity and currency asset. Determine the
type of the order (buy/sell) and yield a 'exists t. OrderInfo t'.

== How does one deal with converting volume and price?

Inside an 'OrderInfo', the 'volume' always uses the 'commodityAsset' as its unit, whereas the 'price' uses the
'currencyAsset' as its unit. In the DEX however, all orders are really sell orders. They are offering some amount of some
asset, and asking for another.

For sell orders, where the offered asset in the DEX order is deemed to be a 'commodityAsset', there is no conversion
necessary. 'volume' is simply in terms of the offered asset amount and the minFill is simply 1. Similarly, 'price' is the same as
the DEX order's price.

But what about buy orders? These are the orders that are offering an asset which is deemed to be a 'currencyAsset'.
And they are asking for an asset which is deemed to be a 'commodityAsset'.

In that case, the price is simply the DEX order's price but flipped (e.g x % y -> y % x).

The volume conversion is slightly more involved, the max volume is the DEX order's price multiplied by the
DEX order's offered amount. If the result is not a whole number, it is ceiled - because more payment is always
accepted, but less is not. The min volume is just the ceiling of the price, because that's the amount of commodity assets
you would need to pay to access one of the offered currencyAssets.
-}
mkOrderInfo
  ∷ OrderAssetPair
  -- ^ The order token Pair with currency and commodity assets
  → PartialOrderInfo
  -- ^ The partialOrderInfo to use when building this OrderInfo.
  → SomeOrderInfo
mkOrderInfo oap poi@PartialOrderInfo {..} = case orderType of
  BuyOrder →
    let maxVolume = ceiling $ (toInteger poiOfferedAmount % 1) * askedPrice
        minVolume = ceiling askedPrice
     in builder SBuyOrder (Volume minVolume maxVolume) $ Price (denominator askedPrice % numerator askedPrice)
  SellOrder → builder SSellOrder (Volume 1 poiOfferedAmount) $ Price askedPrice
 where
  orderType = mkOrderType poiAskedAsset oap
  askedPrice = rationalToGHC poiPrice
  builder ∷ SOrderType t → Volume → Price → SomeOrderInfo
  builder t vol price = SomeOrderInfo $ OrderInfo poiRef t oap vol price poi

isSellOrder ∷ OrderInfo t → Bool
isSellOrder OrderInfo {orderType = SSellOrder} = True
isSellOrder _ = False

isBuyOrder ∷ OrderInfo t → Bool
isBuyOrder OrderInfo {orderType = SBuyOrder} = True
isBuyOrder _ = False

-------------------------------------------------------------------------------
-- Order classification components.
-------------------------------------------------------------------------------

data OrderType = BuyOrder | SellOrder deriving stock (Eq, Show)

data SOrderType t where
  SBuyOrder ∷ SOrderType 'BuyOrder
  SSellOrder ∷ SOrderType 'SellOrder

deriving stock instance Eq (SOrderType t)

deriving stock instance Show (SOrderType t)

-------------------------------------------------------------------------------
-- Order components
-------------------------------------------------------------------------------

{- | The amount of the commodity asset (being brought or sold), represented as a closed interval.

Although the contract now permits fills as low a 1 indivisible token, the volumeMin field is still needed,
because Buy orders are normalized and you can't always fill it for 1. The amount depends on the price of the order.

volumeMin should always be <= volumeMax. Users are responsible for maintaining this invariant.
-}
data Volume = Volume
  { -- | Minimum bound of the Order volume interval.
    volumeMin ∷ !Natural,
    -- | Maximum bound of the Order volume interval.
    volumeMax ∷ !Natural
  }
  deriving stock (Eq, Show, Ord)

-- Q: Could we use 'Int's instead in this volume interval here?

instance Semigroup Volume where
  (Volume minV1 maxV1) <> (Volume minV2 maxV2) = Volume (minV1 + minV2) (maxV1 + maxV2)
  {-# INLINEABLE (<>) #-}

instance Monoid Volume where
  mempty = Volume 0 0
  {-# INLINEABLE mempty #-}

-- | The amount of currency asset (per commodity asset) offered or asked for in an order.
newtype Price = Price {getPrice ∷ Rational} deriving stock (Show, Eq, Ord)

invPrice ∷ Price → Price
invPrice (Price r) = Price $ denominator r % numerator r

instance Semigroup Price where
  p1 <> p2 = Price $ getPrice p1 + getPrice p2
  {-# INLINEABLE (<>) #-}

instance Monoid Price where
  mempty = Price 0
  {-# INLINEABLE mempty #-}

{- | The asset pair in a DEX Order.

All 'OrderAssetPair's constructed out of equivalent raw asset pairs, must compare equal. See: 'equivalentAssetPair'.

For each unique asset pair (see: 'mkAssetPair'), one asset is chosen as the "commodity" (being sold), and the other
is chosen as the "currency" - this makes it simpler to perform order matching.
-}
data OrderAssetPair = OAssetPair
  { currencyAsset ∷ !GYAssetClass,
    commodityAsset ∷ !GYAssetClass
  }
  deriving stock (Eq, Ord, Show)

instance ToJSON OrderAssetPair where
  toJSON OAssetPair {currencyAsset, commodityAsset} =
    Aeson.object
      [ "currencyAsset" .= currencyAsset,
        "commodityAsset" .= commodityAsset
      ]

{- | Two order asset pairs are considered "equivalent" (but not strictly equal, as in 'Eq'),
     if they contain the same 2 assets irrespective of order.
     i.e {currencyAsset = A, commodityAsset = B} and
         {currencyAsset = B, commodityAsset = A} are equivalent.
-}
equivalentAssetPair ∷ OrderAssetPair → OrderAssetPair → Bool
equivalentAssetPair oap oap' = oap == oap' || oap == mkEquivalentAssetPair oap'

mkEquivalentAssetPair ∷ OrderAssetPair → OrderAssetPair
mkEquivalentAssetPair oap =
  OAssetPair
    { commodityAsset = currencyAsset oap,
      currencyAsset = commodityAsset oap
    }

mkOrderAssetPair
  ∷ GYAssetClass
  -- ^ Asset class of the currency asset in the order.
  → GYAssetClass
  -- ^ Asset class of the commodity asset in the order.
  → OrderAssetPair
mkOrderAssetPair curAsset comAsset =
  OAssetPair
    { currencyAsset = curAsset,
      commodityAsset = comAsset
    }

mkOrderType
  ∷ GYAssetClass
  -- ^ Asset class of the asked asset in the order.
  → OrderAssetPair
  -- ^ Order Asset Pair with commodity and currency assets
  → OrderType
mkOrderType asked oap
  | commodityAsset oap == asked = BuyOrder
  | otherwise = SellOrder

data TokenDisplayDetails = TokenDisplayDetails
  { tddTicker ∷ !Text,
    tddDecimals ∷ !Word64,
    tddAssetClass ∷ !GYAssetClass
  }

adaTokenDisplayDetails ∷ TokenDisplayDetails
adaTokenDisplayDetails =
  TokenDisplayDetails
    { tddTicker = "ADA",
      tddDecimals = 6,
      tddAssetClass = GYLovelace
    }

data DexPair = DexPair
  { dpCurrencyToken ∷ !TokenDisplayDetails,
    dpCommodityToken ∷ !TokenDisplayDetails,
    dpMarketPairId ∷ !Text
  }