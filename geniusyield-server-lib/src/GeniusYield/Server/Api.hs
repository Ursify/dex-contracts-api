module GeniusYield.Server.Api (
  GeniusYieldAPI,
  geniusYieldAPI,
  geniusYieldServer,
  MainAPI,
  mainAPI,
  mainServer,
  geniusYieldAPISwagger,
) where

import Control.Lens ((.~), (?~))
import Data.Char (toLower)
import Data.List (isPrefixOf)
import Data.Swagger
import Data.Swagger qualified as Swagger
import Data.Version (showVersion)
import Deriving.Aeson
import Fmt
import GHC.TypeLits (Symbol)
import GeniusYield.Api.Dex.PartialOrder (PORefs (..))
import GeniusYield.Api.Dex.PartialOrderConfig (fetchPartialOrderConfig)
import GeniusYield.GYConfig (GYCoreConfig (cfgNetworkId))
import GeniusYield.Imports
import GeniusYield.OrderBot.Domain.Assets
import GeniusYield.Scripts (PartialOrderConfigInfoF (..))
import GeniusYield.Server.Constants (gitHash)
import GeniusYield.Server.Ctx
import GeniusYield.Server.Dex.Markets (MarketsAPI, handleMarketsApi)
import GeniusYield.Server.Dex.PartialOrder (OrdersAPI, handleOrdersApi)
import GeniusYield.Server.Tx (TxAPI, handleTxApi)
import GeniusYield.Server.Utils
import GeniusYield.Types
import PackageInfo_geniusyield_server_lib qualified as PackageInfo
import Servant
import Servant.Swagger

type SettingsPrefix ∷ Symbol
type SettingsPrefix = "settings"

data Settings = Settings
  { settingsNetwork ∷ !String,
    settingsVersion ∷ !String,
    settingsRevision ∷ !String,
    settingsBackend ∷ !String
  }
  deriving stock (Show, Eq, Generic)
  deriving
    (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix SettingsPrefix, CamelToSnake]] Settings

instance Swagger.ToSchema Settings where
  declareNamedSchema =
    Swagger.genericDeclareNamedSchema Swagger.defaultSchemaOptions {Swagger.fieldLabelModifier = dropSymbolAndCamelToSnake @SettingsPrefix}
      & addSwaggerDescription "Genius Yield Server settings."

type TradingFeesPrefix ∷ Symbol
type TradingFeesPrefix = "tf"

-- TODO: JSON & Swagger instances.
data TradingFees = TradingFees
  { tfFlatMakerFee ∷ !GYNatural,
    tfFlatTakerFee ∷ !GYNatural,
    tfPercentageMakerFee ∷ !GYRational,
    tfPercentageTakerFee ∷ !GYRational
  }
  deriving stock (Show, Eq, Generic)
  deriving
    (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix TradingFeesPrefix, CamelToSnake]] TradingFees

instance Swagger.ToSchema TradingFees where
  declareNamedSchema =
    Swagger.genericDeclareNamedSchema Swagger.defaultSchemaOptions {Swagger.fieldLabelModifier = dropSymbolAndCamelToSnake @TradingFeesPrefix}
      & addSwaggerDescription "Trading fees of DEX."

-------------------------------------------------------------------------------
-- Server's API
-------------------------------------------------------------------------------

type SettingsAPI = Summary "Server settings" :> Description "Get server settings such as network, version, and revision" :> Get '[JSON] Settings

type TradingFeesAPI =
  Summary "Trading fees"
    :> Description "Get trading fees of DEX."
    :> Get '[JSON] TradingFees

type AssetsAPI = Summary "Get assets information" :> Description "Get information for a specific asset." :> Capture "asset" GYAssetClass :> Get '[JSON] AssetDetails

type V0API =
  "settings" :> SettingsAPI
    :<|> "orders" :> OrdersAPI
    :<|> "markets" :> MarketsAPI
    :<|> "tx" :> TxAPI
    :<|> "trading_fees" :> TradingFeesAPI
    :<|> "assets" :> AssetsAPI

type V0 ∷ Symbol
type V0 = "v0"

type GeniusYieldAPI = V0 :> V0API

geniusYieldAPI ∷ Proxy GeniusYieldAPI
geniusYieldAPI = Proxy

infixr 4 +>

type family (+>) (api1 ∷ k) (api2 ∷ Type) where
  (+>) api1 api2 = V0 :> api1 :> api2

geniusYieldAPISwagger ∷ Swagger
geniusYieldAPISwagger =
  toSwagger geniusYieldAPI
    & info
    . title
    .~ "Genius Yield DEX Server API"
      & info
      . version
    .~ "1.0"
      & info
      . license
    ?~ ("Apache-2.0" & url ?~ URL "https://opensource.org/licenses/apache-2-0")
      & info
      . description
    ?~ "API to interact with GeniusYield DEX."
      & applyTagsFor (subOperations (Proxy ∷ Proxy ("tx" +> TxAPI)) (Proxy ∷ Proxy GeniusYieldAPI)) ["Transaction" & description ?~ "Endpoints related to transaction hex such as submitting a transaction"]
      & applyTagsFor (subOperations (Proxy ∷ Proxy ("markets" +> MarketsAPI)) (Proxy ∷ Proxy GeniusYieldAPI)) ["Markets" & description ?~ "Endpoints related to accessing markets information"]
      & applyTagsFor (subOperations (Proxy ∷ Proxy ("orders" +> OrdersAPI)) (Proxy ∷ Proxy GeniusYieldAPI)) ["Orders" & description ?~ "Endpoints related to interacting with orders"]
      & applyTagsFor (subOperations (Proxy ∷ Proxy ("settings" +> SettingsAPI)) (Proxy ∷ Proxy GeniusYieldAPI)) ["Settings" & description ?~ "Endpoint to get server settings such as network, version, and revision"]
      & applyTagsFor (subOperations (Proxy ∷ Proxy ("trading_fees" +> TradingFeesAPI)) (Proxy ∷ Proxy GeniusYieldAPI)) ["Trading Fees" & description ?~ "Endpoint to get trading fees of DEX."]
      & applyTagsFor (subOperations (Proxy ∷ Proxy ("assets" +> AssetsAPI)) (Proxy ∷ Proxy GeniusYieldAPI)) ["Assets" & description ?~ "Endpoint to fetch asset details."]

geniusYieldServer ∷ Ctx → ServerT GeniusYieldAPI IO
geniusYieldServer ctx =
  handleSettings ctx
    :<|> handleOrdersApi ctx
    :<|> handleMarketsApi ctx
    :<|> handleTxApi ctx
    :<|> handleTradingFeesApi ctx
    :<|> handleAssetsApi ctx

type MainAPI =
  GeniusYieldAPI
    :<|> "ui" :> Raw
    :<|> "swagger" :> Raw

mainAPI ∷ Proxy MainAPI
mainAPI = Proxy

mainServer ∷ Ctx → ServerT MainAPI IO
mainServer ctx =
  geniusYieldServer ctx
    :<|> serveDirectoryFileServer "web/dist"
    :<|> serveDirectoryFileServer "web/swagger"

handleSettings ∷ Ctx → IO Settings
handleSettings ctx@Ctx {..} = do
  logInfo ctx "Settings requested."
  pure $ Settings {settingsNetwork = ctxGYCoreConfig & cfgNetworkId & customShowNetworkId, settingsVersion = showVersion PackageInfo.version, settingsRevision = gitHash, settingsBackend = "mmb"}

-- >>> customShowNetworkId GYMainnet
-- "mainnet"
-- >>> customShowNetworkId GYTestnetLegacy
-- "legacy"
-- >>> customShowNetworkId GYPrivnet
-- "privnet"
customShowNetworkId ∷ GYNetworkId → String
customShowNetworkId = show >>> removePrefix "GY" >>> removePrefix "Testnet" >>> lowerFirstChar
 where
  removePrefix ∷ String → String → String
  removePrefix pref str
    | pref `isPrefixOf` str = drop (length pref) str
    | otherwise = str
  lowerFirstChar ∷ String → String
  lowerFirstChar "" = ""
  lowerFirstChar (x : xs) = toLower x : xs

handleTradingFeesApi ∷ Ctx → IO TradingFees
handleTradingFeesApi ctx@Ctx {..} = do
  logInfo ctx "Calculating trading fees."
  (_, pocd) ← runQuery ctx $ fetchPartialOrderConfig $ porRefNft $ dexPORefs $ ctxDexInfo
  pure
    TradingFees
      { tfFlatMakerFee = fromIntegral $ pociMakerFeeFlat pocd,
        tfFlatTakerFee = fromIntegral $ pociTakerFee pocd,
        tfPercentageMakerFee = 100 * pociMakerFeeRatio pocd,
        tfPercentageTakerFee = 100 * pociMakerFeeRatio pocd
      }

handleAssetsApi ∷ Ctx → GYAssetClass → IO AssetDetails
handleAssetsApi ctx@Ctx {..} ac = do
  logInfo ctx $ "Fetching details of asset: " +|| ac ||+ ""
  getAssetDetails ctxMarketsProvider ac