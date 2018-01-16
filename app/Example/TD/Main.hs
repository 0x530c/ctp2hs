{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RecordWildCards       #-}

module Main
  ( main
  ) where

import Bindings.Ctp.Define
import Bindings.Ctp.Struct
import Bindings.Ctp.TD
import Control.Concurrent.STM
import Control.Monad
import Data.Default
import Data.Monoid            ((<>))
import Options.Applicative

data TDConfig = TDConfig
  { userID   :: String
  , password :: String
  , brokerID :: String
  , front    :: String
  } deriving (Show)

data TDState = TDState
  { cfg   :: TDConfig
  , reqID :: TVar Int
  , api   :: TDObject
  }

incReqID :: TDState -> IO Int
incReqID TDState {..} = atomically $ modifyTVar reqID (+ 1) >> readTVar reqID

unlessErrorRspInfo :: CThostFtdcRspInfoField -> IO () -> IO ()
unlessErrorRspInfo CThostFtdcRspInfoField {..} a =
  if errorID /= 0
    then putStrLn $ "Error: (" ++ show errorID ++ ") " ++ errorMsg
    else a

onFrontConnected' :: TDState -> OnFrontConnected
onFrontConnected' s@TDState {..} = do
  putStrLn "onFrontConnected ..."
  void $ incReqID s >>= tdReqUserLogin api (req cfg)
  where
    req :: TDConfig -> CThostFtdcReqUserLoginField
    req TDConfig {..} =
      def {password = password, userID = userID, brokerID = brokerID}

onRspUserLogin' :: TDState -> OnRspUserLogin
onRspUserLogin' s@TDState {..} _ rspInfo _ _ = do
  putStrLn "onRspUserLogin ..."
  unlessErrorRspInfo rspInfo $ do
    tdGetTradingDay api >>= putStrLn . ("交易日: " ++)
    void $ incReqID s >>= tdReqSettlementInfoConfirm api (req cfg)
  where
    req :: TDConfig -> CThostFtdcSettlementInfoConfirmField
    req TDConfig {..} = def {investorID = userID, brokerID = brokerID}

onRspSettlementInfoConfirm' :: TDState -> OnRspSettlementInfoConfirm
onRspSettlementInfoConfirm' s@TDState {..} _ rspInfo _ _ = do
  putStrLn "onRspSettlementInfoConfirm ..."
  unlessErrorRspInfo rspInfo . void $ incReqID s >>= tdReqQryInstrument api req
  where
    req :: CThostFtdcQryInstrumentField
    req = def

onRspQryInstrument' :: OnRspQryInstrument
onRspQryInstrument' CThostFtdcInstrumentField {..} _ _ _ =
  putStrLn $ "> " ++ instrumentName

main :: IO ()
main = do
  cfg' <- execParser opts
  zeroReqID <- atomically $ newTVar 0
  td <- tdCreate "/tmp/ctphstd"
  let s = TDState {cfg = cfg', reqID = zeroReqID, api = td}
  tdGetApiVersion >>= putStrLn
  tdRegisterSpi td $
    def
    { onFrontConnected = Just $ onFrontConnected' s
    , onRspUserLogin = Just $ onRspUserLogin' s
    , onRspSettlementInfoConfirm = Just $ onRspSettlementInfoConfirm' s
    , onRspQryInstrument = Just onRspQryInstrument'
    }
  tdSubscribePublicTopic td ThostTertRestart
  tdSubscribePrivateTopic td ThostTertRestart
  tdRegisterFront td . front $ cfg s
  tdInit td
  _ <- getLine
  tdRelease td
  where
    opts :: ParserInfo TDConfig
    opts = info (tdConfig <**> helper) fullDesc
    tdConfig :: Parser TDConfig
    tdConfig =
      TDConfig <$>
      strOption (long "user" <> short 'u' <> metavar "USER" <> help "用户编号") <*>
      strOption (long "password" <> short 'p' <> metavar "PWD" <> help "用户密码") <*>
      strOption
        (long "broker" <> short 'b' <> metavar "BROKER" <> value "9999" <>
         help "经纪商编号") <*>
      strOption
        (long "front" <> short 'f' <> metavar "ADDR" <>
         value "tcp://180.168.146.187:10000" <>
         help "交易前置地址")
