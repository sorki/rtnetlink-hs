{-|
Module      : System.Linux.RTNetlink.Link
Description : ADTs for creating, destroying, modifying, and getting info
              about links.
Copyright   : (c) Formaltech Inc. 2017
License     : BSD3
Maintainer  : protob3n@gmail.com
Stability   : experimental
Portability : Linux
-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}
module System.Linux.RTNetlink.Link where

import Control.Applicative ((<$>), (<*>))
import Data.Bits ((.&.))
import Data.Int (Int32)
import Data.Monoid ((<>))
import Data.Serialize
import Data.Word (Word8, Word32)
import qualified Data.ByteString as S

import System.Linux.RTNetlink.Packet
import System.Linux.RTNetlink.Message

#include <linux/if_link.h>
#include <linux/rtnetlink.h>
#include <net/if.h>

-- | A link identified by its index.
newtype LinkIndex = LinkIndex Int
    deriving (Show, Eq, Num, Ord)
instance Message LinkIndex where
    type MessageHeader LinkIndex = IfInfoMsg
    messageHeader (LinkIndex ix) = IfInfoMsg (fromIntegral ix) 0 0
instance Destroy LinkIndex where
    destroyTypeNumber = const #{const RTM_DELLINK}
instance Request LinkIndex where
    requestTypeNumber = const #{const RTM_GETLINK}
instance Reply LinkIndex where
    type ReplyHeader LinkIndex = IfInfoMsg
    replyTypeNumbers = const [#{const RTM_NEWLINK}]
    fromNLMessage    = Just . LinkIndex . fromIntegral . ifIndex . nlmHeader

-- | A link identified by its name.
newtype LinkName = LinkName S.ByteString
    deriving (Show, Eq)
instance Message LinkName where
    type MessageHeader LinkName = IfInfoMsg
    messageAttrs  (LinkName bs) = AttributeList
        [cStringAttr #{const IFLA_IFNAME} $ S.take #{const IFNAMSIZ} bs]
instance Destroy LinkName where
    destroyTypeNumber = const #{const RTM_DELLINK}
instance Request LinkName where
    requestTypeNumber = const #{const RTM_GETLINK}
instance Reply LinkName where
    type ReplyHeader LinkName = IfInfoMsg
    replyTypeNumbers = const [#{const RTM_NEWLINK}]
    fromNLMessage m  = do
        a <- findAttribute [#{const IFLA_IFNAME}] . nlmAttrs $ m
        n <- S.takeWhile (/=0) <$> attributeData a
        return $ LinkName n

-- | An ethernet address.
data LinkEther = LinkEther Word8 Word8 Word8 Word8 Word8 Word8
    deriving Eq
instance Show LinkEther where
    show (LinkEther a b c d e f) = hex a <:> hex b <:> hex c <:> hex d <:> hex e <:> hex f
        where
        hex w   = hexdig (w `div` 0x10) : hexdig (w `rem` 0x10) : []
        hexdig  = (!!) "0123456789abcdef" . fromIntegral
        s <:> t = s ++ ":" ++ t :: String
instance Serialize LinkEther where
    put (LinkEther a b c d e f) = put a >> put b >> put c >> put d >> put e >> put f
    get = LinkEther <$> get <*> get <*> get <*> get <*> get <*> get
instance Message LinkEther where
    type MessageHeader LinkEther = IfInfoMsg
    messageAttrs  e = AttributeList [Attribute #{const IFLA_ADDRESS} $ encode e]
instance Reply LinkEther where
    type ReplyHeader LinkEther = IfInfoMsg
    replyTypeNumbers = const [#{const RTM_NEWLINK}]
    fromNLMessage m  = do
        a <- findAttribute [#{const IFLA_ADDRESS}] . nlmAttrs $ m
        d <- attributeData a
        decodeMaybe d

-- | Link wildcard.
data AnyLink = AnyLink
    deriving (Show, Eq)
instance Message AnyLink where
    type MessageHeader AnyLink = IfInfoMsg
instance Request AnyLink where
    requestTypeNumber = const #{const RTM_GETLINK}
    requestNLFlags    = const dumpNLFlags

-- | A dummy interface.
newtype Dummy = Dummy LinkName
    deriving (Show, Eq)
instance Message Dummy where
    type MessageHeader Dummy = IfInfoMsg
    messageHeader (Dummy name) = messageHeader name
    messageAttrs  (Dummy name) = messageAttrs name <> AttributeList
        [ AttributeNest #{const IFLA_LINKINFO}
            [ cStringAttr #{const IFLA_INFO_KIND} "dummy" ]
        ]
instance Create Dummy where
    createTypeNumber = const #{const RTM_NEWLINK}

-- | A bridge interface.
newtype Bridge = Bridge LinkName
    deriving (Show, Eq)
instance Message Bridge where
    type MessageHeader Bridge = IfInfoMsg
    messageAttrs  (Bridge name) = messageAttrs name <> AttributeList
        [ AttributeNest #{const IFLA_LINKINFO}
            [ cStringAttr #{const IFLA_INFO_KIND} "bridge" ]
        ]
instance Create Bridge where
    createTypeNumber = const #{const RTM_NEWLINK}

-- | The state of a link.
data LinkState = Up | Down
    deriving (Show, Eq)
instance Reply LinkState where
    type ReplyHeader LinkState = IfInfoMsg
    replyTypeNumbers = const [#{const RTM_NEWLINK}]
    fromNLMessage m  = Just $ if flag == 0 then Down else Up
        where flag = ifFlags (nlmHeader m) .&. #{const IFF_UP}
instance Change LinkName LinkState where
    changeTypeNumber _ _ = #{const RTM_SETLINK}
    changeAttrs      n _ = messageAttrs n
    changeHeader     n s = IfInfoMsg ix flag #{const IFF_UP}
        where
        ix   = ifIndex $ messageHeader n
        flag = if s == Up then #{const IFF_UP} else 0
instance Change LinkIndex LinkState where
    changeTypeNumber _ _ = #{const RTM_SETLINK}
    changeAttrs      n _ = messageAttrs n
    changeHeader     n s = IfInfoMsg ix flag #{const IFF_UP}
        where
        ix   = ifIndex $ messageHeader n
        flag = if s == Up then #{const IFF_UP} else 0

-- | The header corresponding to link messages, based on 'struct ifinfomsg'
-- from 'linux/if_link.h'.
data IfInfoMsg = IfInfoMsg
    { ifIndex  :: Int32  -- ^ The index of the link.
    , ifFlags  :: Word32 -- ^ Operational flags of the link.
    , ifChange :: Word32 -- ^ Change mask for link flags.
    } deriving (Show, Eq)
instance Sized IfInfoMsg where
    size = const #{const sizeof(struct ifinfomsg)}
instance Serialize IfInfoMsg where
    put IfInfoMsg {..} = do
        putWord8      #{const AF_UNSPEC}
        putWord8      0
        putWord16host 0
        putInt32host  ifIndex
        putWord32host ifFlags
        putWord32host ifChange
    get = do
        skip 4
        ifIndex  <- getInt32le
        ifFlags  <- getWord32host
        ifChange <- getWord32host
        return $ IfInfoMsg {..}
instance Header IfInfoMsg where
    emptyHeader = IfInfoMsg 0 0 0

newtype LinkDeleted a = LinkDeleted a
    deriving (Eq, Show)
instance Reply a => Reply (LinkDeleted a) where
    type ReplyHeader (LinkDeleted a)  = ReplyHeader a
    replyTypeNumbers _             = [#{const RTM_DELLINK}]
    fromNLMessage    m =
          LinkDeleted <$> fromNLMessage m
