{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}
module NetSim.TwoPhaseCommit(
  initNetwork,
  initNetworkMetadata,
  tpcInvariant
  ) where

import NetSim.Core
import NetSim.Invariant

import Control.Monad (forM)

data State = CoordinatorInit [NodeID]
           | CoordinatorCommit [NodeID]
           | CoordinatorAbort [NodeID]
           | ParticipantInit
           | ParticipantGotRequest NodeID
           | ParticipantRespondedYes NodeID
           | ParticipantRespondedNo NodeID
           | ParticipantCommit NodeID
           | ParticipantAbort NodeID
           deriving (Show, Eq)

prepare :: Alternative f => Protlet f State
prepare = Broadcast "Prepare" coordinatorBroadcast participantReceive participantSend
  where
    coordinatorBroadcast = \case
      CoordinatorInit participants ->
        pure (zip participants (repeat []), receiveResponses participants)
      _ -> empty
    receiveResponses participants responses =
      if any (/= [1]) responses
      then CoordinatorAbort participants
      else CoordinatorCommit participants

    participantReceive Message{..} = \case
      ParticipantInit ->
        pure $ ParticipantGotRequest _msgFrom
      _ -> empty

    participantSend nodeID = \case
      ParticipantGotRequest coordinator ->
        pure (buildResponse nodeID coordinator False, ParticipantRespondedNo coordinator) <|>
        pure (buildResponse nodeID coordinator True, ParticipantRespondedYes coordinator)
      _ -> empty

    buildResponse nodeID coordinator b = Message {
      _msgFrom = nodeID,
      _msgTag = "Prepare__Response",
      _msgBody = if b then [1] else [0],
      _msgTo = coordinator
      }

decide :: Alternative f => Protlet f State
decide = Broadcast "Decide" coordinatorBroadcast participantReceive participantRespond
  where
    coordinatorBroadcast = \case
      CoordinatorAbort participants ->
        pure (zip participants (repeat [0]), receiveResponses participants)
      CoordinatorCommit participants ->
        pure (zip participants (repeat [1]), receiveResponses participants)
      _ -> empty
    receiveResponses participants _ = CoordinatorInit participants

    participantReceive Message{..} = \case
      ParticipantRespondedYes coordinator | [0] <- _msgBody ->
                                            pure $ ParticipantAbort coordinator
                                          | [1] <- _msgBody ->
                                            pure $ ParticipantCommit coordinator
      ParticipantRespondedNo coordinator  |  [_] <- _msgBody ->
                                            pure $ ParticipantAbort coordinator
      _ -> empty

    participantRespond nodeID = \case
      ParticipantAbort coordinator ->
        pure (buildResponse nodeID coordinator False, ParticipantInit)
      ParticipantCommit coordinator ->
        pure (buildResponse nodeID coordinator True, ParticipantInit)
      _ -> empty

    buildResponse nodeID coordinator b = Message {
      _msgFrom = nodeID,
      _msgTag = "Decide__Response",
      _msgBody = if b then [1] else [0],
      _msgTo = coordinator
      }

initNetwork :: Alternative f => Network f State
initNetwork = initializeNetwork nodes protlets
  where
    nodes = [ (0, CoordinatorInit [1,2,3])
            , (1, ParticipantInit)
            , (2, ParticipantInit)
            , (3, ParticipantInit)
            ]
    protlets = [prepare, decide]

initNetworkMetadata :: TPCMetaData
initNetworkMetadata = TPCMetaData {
  _coordinator = 0,
  _participants = [1, 2, 3]
  }

data TPCMetaData = TPCMetaData {
  _coordinator :: NodeID,
  _participants :: [NodeID]
  }

-- Invariant Utilities
type TPCInv = Invariant TPCMetaData State Bool

getParticipants :: Invariant TPCMetaData s [NodeID]
getParticipants = _participants . fst

getCoordinator :: Invariant TPCMetaData s NodeID
getCoordinator = _coordinator . fst

forallParticipants :: (NodeID -> TPCInv) -> TPCInv
forallParticipants predicate = do
  participants <- getParticipants
  forNodes participants predicate

forCoordinator :: (NodeID -> TPCInv) -> TPCInv
forCoordinator predicate = do
  coordinator <- getCoordinator
  forNodes [coordinator] predicate


-- # Top-Level Invariant

tpcInvariant :: TPCInv
tpcInvariant = everythingInit 
          <||> phaseOne
          <||> phaseTwo

-- # Initial State

everythingInit :: TPCInv
everythingInit = do
  coordinator <- getCoordinator
  participants <- getParticipants
  forCoordinator (runningInState (CoordinatorInit participants))
    <&&> forallParticipants (\pt ->
           noOutstandingMessagesBetween coordinator pt
             <&&> runningInState ParticipantInit pt)

-- # Phase 1

participantPhaseOne :: NodeID -> TPCInv
participantPhaseOne pt = do
  cn <- getCoordinator 
  foldr1 (<||>) [
    runningInState ParticipantInit pt
    <&&> noMessageFromTo pt cn
    <&&> messageAt pt "Prepare__Broadcast" [] cn,

    runningInState (ParticipantGotRequest cn) pt
    <&&> noOutstandingMessagesBetween pt cn,

    runningInState (ParticipantRespondedYes cn) pt
    <&&> noMessageFromTo cn pt
    <&&> messageAt cn "Prepare__Response" [1] pt,

    runningInState (ParticipantRespondedNo cn) pt
    <&&> noMessageFromTo cn pt
    <&&> messageAt cn "Prepare__Response" [0] pt
    ]

participantPhaseOneResponded :: Bool -> NodeID -> TPCInv
participantPhaseOneResponded comitted pt = do
  cn <- getCoordinator
  noMessageFromTo cn pt <&&>
    if comitted
      then runningInState (ParticipantRespondedYes cn) pt
      else runningInState (ParticipantRespondedNo cn) pt

coordinatorPhaseOne :: NodeID -> TPCInv
coordinatorPhaseOne cn = 
  blockingOn "Prepare__Response" cn $ \responses ->
      and <$> forM responses (\Message{..} ->
        participantPhaseOneResponded (_msgBody == [1]) _msgFrom)


phaseOne :: TPCInv
phaseOne =
  forCoordinator coordinatorPhaseOne <&&>
  forallParticipants participantPhaseOne

-- # Phase 2

participantPhaseTwoCommit :: NodeID -> TPCInv
participantPhaseTwoCommit pt = do
  cn <- getCoordinator
  foldr1 (<||>) [
    runningInState (ParticipantRespondedYes cn) pt
    <&&> messageAt pt "Decide__Broadcast" [1] cn
    <&&> noMessageFromTo pt cn,

    runningInState (ParticipantCommit cn) pt
    <&&> noOutstandingMessagesBetween cn pt,

    runningInState (ParticipantInit) pt
    <&&> noMessageFromTo cn pt
    <&&> messageAt cn "Decide__Response" [1] pt
    ]

participantPhaseTwoAbort :: NodeID -> TPCInv
participantPhaseTwoAbort pt = do
  cn <- getCoordinator
  foldr1 (<||>) [
    (runningInState (ParticipantRespondedYes cn) pt <||>
      runningInState (ParticipantRespondedNo cn) pt)
    <&&> messageAt pt "Decide__Broadcast" [0] cn
    <&&> noMessageFromTo pt cn,

    runningInState (ParticipantAbort cn) pt
    <&&> noOutstandingMessagesBetween cn pt,

    runningInState (ParticipantInit) pt
    <&&> noMessageFromTo cn pt
    <&&> messageAt cn "Decide__Response" [0] pt
    ]

coordinatorPhaseTwoSendAborts :: NodeID -> TPCInv
coordinatorPhaseTwoSendAborts cn = do
  participants <- getParticipants
  runningInState (CoordinatorAbort participants) cn <&&>
    (or <$> forM participants 
              (runningInState (ParticipantRespondedNo cn)))

coordinatorPhaseTwoReceiveAborts :: NodeID -> TPCInv
coordinatorPhaseTwoReceiveAborts cn =
  blockingOn "Decide__Response" cn $ \_ -> 
    forallParticipants participantPhaseTwoAbort

coordinatorPhaseTwoSendCommits :: NodeID -> TPCInv
coordinatorPhaseTwoSendCommits cn = do
  participants <- getParticipants
  runningInState (CoordinatorCommit participants) cn <&&>
    (and <$> forM participants 
              (runningInState (ParticipantRespondedYes cn)))

coordinatorPhaseTwoReceiveCommits :: NodeID -> TPCInv
coordinatorPhaseTwoReceiveCommits cn =
  blockingOn "Decide__Response" cn $ \_ -> 
    forallParticipants participantPhaseTwoCommit

phaseTwoCommit :: TPCInv
phaseTwoCommit = do
  cn <- getCoordinator
  coordinatorPhaseTwoSendCommits cn <||>
    coordinatorPhaseTwoReceiveCommits cn

phaseTwoAbort :: TPCInv
phaseTwoAbort = do
  cn <- getCoordinator
  coordinatorPhaseTwoSendAborts cn <||>
    coordinatorPhaseTwoReceiveAborts cn

phaseTwo :: TPCInv
phaseTwo = phaseTwoCommit <||> phaseTwoAbort  