{- This module contains a framework to build EVE Online bots and intel tools.
   Features:
   + Read from the game client using Sanderling memory reading and parse the user interface from the memory reading (https://github.com/Arcitectus/Sanderling).
   + Play sounds.
   + Send mouse and keyboard input to the game client.
   + Forward the app settings from the host.

   The framework automatically selects an EVE Online client process and finishes the session when that process disappears.
   When multiple game clients are open, the framework prioritizes the one with the topmost window. This approach helps users control which game client is picked by an app.
   To use the framework, import this module and use the `initState` and `processEvent` functions.
-}


module EveOnline.BotFramework exposing
    ( BotEffect(..)
    , BotEvent(..)
    , BotEventContext
    , BotEventResponse(..)
    , SetupState
    , StateIncludingFramework
    , getEntropyIntFromUserInterface
    , initState
    , processEvent
    )

import BotEngine.Interface_To_Host_20200318 as InterfaceToHost
import Common.FNV
import Dict
import EveOnline.MemoryReading
import EveOnline.ParseUserInterface
import EveOnline.VolatileHostInterface as VolatileHostInterface
import EveOnline.VolatileHostScript as VolatileHostScript


type BotEvent
    = MemoryReadingCompleted EveOnline.ParseUserInterface.ParsedUserInterface


type BotEventResponse
    = ContinueSession ContinueSessionStructure
    | FinishSession { statusDescriptionText : String }


type alias ContinueSessionStructure =
    { effects : List BotEffect
    , millisecondsToNextReadingFromGame : Int
    , statusDescriptionText : String
    }


type BotEffect
    = EffectOnGameClientWindow VolatileHostInterface.EffectOnWindowStructure
    | EffectConsoleBeepSequence (List ConsoleBeepStructure)


type alias BotEventContext =
    { timeInMilliseconds : Int
    , appSettings : Maybe String
    , sessionTimeLimitInMilliseconds : Maybe Int
    }


type alias StateIncludingFramework botState =
    { setup : SetupState
    , botState : BotAndLastEventState botState
    , timeInMilliseconds : Int
    , lastTaskIndex : Int
    , taskInProgress : Maybe { startTimeInMilliseconds : Int, taskIdString : String, taskDescription : String }
    , appSettings : Maybe String
    , sessionTimeLimitInMilliseconds : Maybe Int
    }


type alias BotAndLastEventState botState =
    { botState : botState
    , lastEvent : Maybe { timeInMilliseconds : Int, eventResult : ( botState, BotEventResponse ) }
    , effectQueue : BotEffectQueue
    }


type alias BotEffectQueue =
    List { timeInMilliseconds : Int, effect : BotEffect }


type alias SetupState =
    { createVolatileHostResult : Maybe (Result InterfaceToHost.CreateVolatileHostErrorStructure InterfaceToHost.CreateVolatileHostComplete)
    , requestsToVolatileHostCount : Int
    , lastRequestToVolatileHostResult : Maybe (Result String InterfaceToHost.RequestToVolatileHostComplete)
    , gameClientProcesses : Maybe (List VolatileHostInterface.GameClientProcessSummaryStruct)
    , searchUIRootAddressResult : Maybe VolatileHostInterface.SearchUIRootAddressResultStructure
    , lastMemoryReading : Maybe { timeInMilliseconds : Int, memoryReadingResult : VolatileHostInterface.GetMemoryReadingResultStructure }
    , memoryReadingDurations : List Int
    }


type SetupTask
    = ContinueSetup SetupState InterfaceToHost.Task String
    | OperateBot
        { buildTaskFromBotEffect : BotEffect -> InterfaceToHost.Task
        , getMemoryReadingTask : InterfaceToHost.Task
        , releaseVolatileHostTask : InterfaceToHost.Task
        }
    | FrameworkStopSession String


type alias ConsoleBeepStructure =
    { frequency : Int
    , durationInMs : Int
    }


volatileHostRecycleInterval : Int
volatileHostRecycleInterval =
    400


initSetup : SetupState
initSetup =
    { createVolatileHostResult = Nothing
    , requestsToVolatileHostCount = 0
    , lastRequestToVolatileHostResult = Nothing
    , gameClientProcesses = Nothing
    , searchUIRootAddressResult = Nothing
    , lastMemoryReading = Nothing
    , memoryReadingDurations = []
    }


initState : botState -> StateIncludingFramework botState
initState botState =
    { setup = initSetup
    , botState =
        { botState = botState
        , lastEvent = Nothing
        , effectQueue = []
        }
    , timeInMilliseconds = 0
    , lastTaskIndex = 0
    , taskInProgress = Nothing
    , appSettings = Nothing
    , sessionTimeLimitInMilliseconds = Nothing
    }


processEvent :
    (BotEventContext -> BotEvent -> botState -> ( botState, BotEventResponse ))
    -> InterfaceToHost.BotEvent
    -> StateIncludingFramework botState
    -> ( StateIncludingFramework botState, InterfaceToHost.BotResponse )
processEvent botProcessEvent fromHostEvent stateBeforeIntegratingEvent =
    let
        ( stateBefore, maybeBotEvent ) =
            stateBeforeIntegratingEvent |> integrateFromHostEvent fromHostEvent

        ( state, responseBeforeAddingStatusMessage ) =
            case stateBefore.taskInProgress of
                Nothing ->
                    processEventNotWaitingForTaskCompletion botProcessEvent maybeBotEvent stateBefore

                Just taskInProgress ->
                    ( stateBefore
                    , { statusDescriptionText = "Waiting for completion of task '" ++ taskInProgress.taskIdString ++ "': " ++ taskInProgress.taskDescription
                      , notifyWhenArrivedAtTime = Just { timeInMilliseconds = stateBefore.timeInMilliseconds + 300 }
                      , startTasks = []
                      }
                        |> InterfaceToHost.ContinueSession
                    )

        statusMessagePrefix =
            (state |> statusReportFromState) ++ "\nCurrent activity: "

        response =
            case responseBeforeAddingStatusMessage of
                InterfaceToHost.ContinueSession continueSession ->
                    { continueSession
                        | statusDescriptionText = statusMessagePrefix ++ continueSession.statusDescriptionText
                    }
                        |> InterfaceToHost.ContinueSession

                InterfaceToHost.FinishSession finishSession ->
                    { finishSession
                        | statusDescriptionText = statusMessagePrefix ++ finishSession.statusDescriptionText
                    }
                        |> InterfaceToHost.FinishSession
    in
    ( state, response )


processEventNotWaitingForTaskCompletion :
    (BotEventContext -> BotEvent -> botState -> ( botState, BotEventResponse ))
    -> Maybe ( BotEvent, BotEventContext )
    -> StateIncludingFramework botState
    -> ( StateIncludingFramework botState, InterfaceToHost.BotResponse )
processEventNotWaitingForTaskCompletion botProcessEvent maybeBotEvent stateBefore =
    case stateBefore.setup |> getNextSetupTask of
        ContinueSetup setupState setupTask setupTaskDescription ->
            let
                taskIndex =
                    stateBefore.lastTaskIndex + 1

                taskIdString =
                    "setup-" ++ (taskIndex |> String.fromInt)
            in
            ( { stateBefore
                | setup = setupState
                , lastTaskIndex = taskIndex
                , taskInProgress =
                    Just
                        { startTimeInMilliseconds = stateBefore.timeInMilliseconds
                        , taskIdString = taskIdString
                        , taskDescription = setupTaskDescription
                        }
              }
            , { startTasks = [ { taskId = InterfaceToHost.taskIdFromString taskIdString, task = setupTask } ]
              , statusDescriptionText = "Continue setup: " ++ setupTaskDescription
              , notifyWhenArrivedAtTime = Just { timeInMilliseconds = stateBefore.timeInMilliseconds + 1000 }
              }
                |> InterfaceToHost.ContinueSession
            )

        OperateBot operateBot ->
            if volatileHostRecycleInterval < stateBefore.setup.requestsToVolatileHostCount then
                let
                    taskIndex =
                        stateBefore.lastTaskIndex + 1

                    taskIdString =
                        "maintain-" ++ (taskIndex |> String.fromInt)

                    setupStateBefore =
                        stateBefore.setup

                    setupState =
                        { setupStateBefore | createVolatileHostResult = Nothing }

                    setupTaskDescription =
                        "Recycle the volatile host after " ++ (setupStateBefore.requestsToVolatileHostCount |> String.fromInt) ++ " requests."
                in
                ( { stateBefore
                    | setup = setupState
                    , lastTaskIndex = taskIndex
                    , taskInProgress =
                        Just
                            { startTimeInMilliseconds = stateBefore.timeInMilliseconds
                            , taskIdString = taskIdString
                            , taskDescription = setupTaskDescription
                            }
                  }
                , { startTasks =
                        [ { taskId = InterfaceToHost.taskIdFromString taskIdString
                          , task = operateBot.releaseVolatileHostTask
                          }
                        ]
                  , statusDescriptionText = "Continue setup: " ++ setupTaskDescription
                  , notifyWhenArrivedAtTime = Just { timeInMilliseconds = stateBefore.timeInMilliseconds + 1000 }
                  }
                    |> InterfaceToHost.ContinueSession
                )

            else
                let
                    botStateBefore =
                        stateBefore.botState

                    maybeBotEventResult =
                        maybeBotEvent
                            |> Maybe.map
                                (\( botEvent, botEventContext ) -> botStateBefore.botState |> botProcessEvent botEventContext botEvent)

                    botStateBeforeProcessEffects =
                        case maybeBotEventResult of
                            Nothing ->
                                stateBefore.botState

                            Just ( newBotState, botEventResponse ) ->
                                let
                                    effectQueue =
                                        case botEventResponse of
                                            FinishSession _ ->
                                                []

                                            ContinueSession continueSessionResponse ->
                                                continueSessionResponse.effects
                                                    |> List.map
                                                        (\botEffect ->
                                                            { timeInMilliseconds = stateBefore.timeInMilliseconds, effect = botEffect }
                                                        )
                                in
                                { botStateBefore
                                    | botState = newBotState
                                    , lastEvent = Just { timeInMilliseconds = stateBefore.timeInMilliseconds, eventResult = ( newBotState, botEventResponse ) }
                                    , effectQueue = effectQueue
                                }

                    ( botEffectQueue, botEffectTask ) =
                        case
                            botStateBeforeProcessEffects.effectQueue
                                |> dequeueNextEffectFromBotState { currentTimeInMs = stateBefore.timeInMilliseconds }
                        of
                            NoEffect ->
                                ( botStateBeforeProcessEffects.effectQueue, Nothing )

                            ForwardEffect forward ->
                                ( forward.newQueueState, forward.effect |> operateBot.buildTaskFromBotEffect |> Just )

                    botState =
                        { botStateBeforeProcessEffects | effectQueue = botEffectQueue }

                    timeForNextMemoryReadingGeneral =
                        (stateBefore.setup.lastMemoryReading |> Maybe.map .timeInMilliseconds |> Maybe.withDefault 0) + 10000

                    timeForNextMemoryReadingFromBot =
                        botState.lastEvent
                            |> Maybe.andThen
                                (\botLastEvent ->
                                    case botLastEvent.eventResult |> Tuple.second of
                                        ContinueSession continueSessionResponse ->
                                            Just (botLastEvent.timeInMilliseconds + continueSessionResponse.millisecondsToNextReadingFromGame)

                                        FinishSession _ ->
                                            Nothing
                                )
                            |> Maybe.withDefault 0

                    timeForNextMemoryReading =
                        min timeForNextMemoryReadingGeneral timeForNextMemoryReadingFromBot

                    memoryReadingTasks =
                        if timeForNextMemoryReading < stateBefore.timeInMilliseconds then
                            [ operateBot.getMemoryReadingTask ]

                        else
                            []

                    botFinishesSession =
                        botState.lastEvent
                            |> Maybe.map
                                (\botLastEvent ->
                                    case botLastEvent.eventResult |> Tuple.second of
                                        ContinueSession _ ->
                                            False

                                        FinishSession _ ->
                                            True
                                )
                            |> Maybe.withDefault False

                    ( taskInProgress, startTasks ) =
                        (botEffectTask |> Maybe.map List.singleton |> Maybe.withDefault [])
                            ++ memoryReadingTasks
                            |> List.head
                            |> Maybe.map
                                (\task ->
                                    let
                                        taskIdString =
                                            "operate-bot"
                                    in
                                    ( Just
                                        { startTimeInMilliseconds = stateBefore.timeInMilliseconds
                                        , taskIdString = taskIdString
                                        , taskDescription = "From bot effect or memory reading."
                                        }
                                    , [ { taskId = InterfaceToHost.taskIdFromString taskIdString, task = task } ]
                                    )
                                )
                            |> Maybe.withDefault ( stateBefore.taskInProgress, [] )

                    setupStateBefore =
                        stateBefore.setup

                    setupState =
                        { setupStateBefore
                            | requestsToVolatileHostCount = setupStateBefore.requestsToVolatileHostCount + (startTasks |> List.length)
                        }

                    state =
                        { stateBefore | setup = setupState, botState = botState, taskInProgress = taskInProgress }
                in
                if botFinishesSession then
                    ( state, { statusDescriptionText = "The app finished the session." } |> InterfaceToHost.FinishSession )

                else
                    ( state
                    , { startTasks = startTasks
                      , statusDescriptionText = "Operate bot."
                      , notifyWhenArrivedAtTime = Just { timeInMilliseconds = stateBefore.timeInMilliseconds + 500 }
                      }
                        |> InterfaceToHost.ContinueSession
                    )

        FrameworkStopSession reason ->
            ( stateBefore
            , InterfaceToHost.FinishSession { statusDescriptionText = "Stop session (" ++ reason ++ ")" }
            )


integrateFromHostEvent : InterfaceToHost.BotEvent -> StateIncludingFramework a -> ( StateIncludingFramework a, Maybe ( BotEvent, BotEventContext ) )
integrateFromHostEvent fromHostEvent stateBefore =
    let
        ( state, maybeBotEvent ) =
            case fromHostEvent of
                InterfaceToHost.ArrivedAtTime { timeInMilliseconds } ->
                    ( { stateBefore | timeInMilliseconds = timeInMilliseconds }, Nothing )

                InterfaceToHost.CompletedTask taskComplete ->
                    let
                        ( setupState, maybeBotEventFromTaskComplete ) =
                            stateBefore.setup
                                |> integrateTaskResult ( stateBefore.timeInMilliseconds, taskComplete.taskResult )
                    in
                    ( { stateBefore | setup = setupState, taskInProgress = Nothing }, maybeBotEventFromTaskComplete )

                InterfaceToHost.SetAppSettings appSettings ->
                    ( { stateBefore | appSettings = Just appSettings }, Nothing )

                InterfaceToHost.SetSessionTimeLimit sessionTimeLimit ->
                    ( { stateBefore | sessionTimeLimitInMilliseconds = Just sessionTimeLimit.timeInMilliseconds }, Nothing )
    in
    ( state
    , maybeBotEvent
        |> Maybe.map
            (\botEvent ->
                ( botEvent
                , { timeInMilliseconds = state.timeInMilliseconds
                  , appSettings = state.appSettings
                  , sessionTimeLimitInMilliseconds = state.sessionTimeLimitInMilliseconds
                  }
                )
            )
    )


integrateTaskResult : ( Int, InterfaceToHost.TaskResultStructure ) -> SetupState -> ( SetupState, Maybe BotEvent )
integrateTaskResult ( timeInMilliseconds, taskResult ) setupStateBefore =
    case taskResult of
        InterfaceToHost.CreateVolatileHostResponse createVolatileHostResult ->
            ( { setupStateBefore
                | createVolatileHostResult = Just createVolatileHostResult
                , requestsToVolatileHostCount = 0
              }
            , Nothing
            )

        InterfaceToHost.RequestToVolatileHostResponse (Err InterfaceToHost.HostNotFound) ->
            ( { setupStateBefore | createVolatileHostResult = Nothing }, Nothing )

        InterfaceToHost.RequestToVolatileHostResponse (Ok requestResult) ->
            let
                requestToVolatileHostResult =
                    case requestResult.exceptionToString of
                        Nothing ->
                            Ok requestResult

                        Just exception ->
                            Err ("Exception from host: " ++ exception)

                maybeResponseFromVolatileHost =
                    requestToVolatileHostResult
                        |> Result.toMaybe
                        |> Maybe.andThen
                            (\fromHostResult ->
                                fromHostResult.returnValueToString
                                    |> Maybe.withDefault ""
                                    |> VolatileHostInterface.deserializeResponseFromVolatileHost
                                    |> Result.toMaybe
                                    |> Maybe.map (\responseFromVolatileHost -> { fromHostResult = fromHostResult, responseFromVolatileHost = responseFromVolatileHost })
                            )

                setupStateWithScriptRunResult =
                    { setupStateBefore | lastRequestToVolatileHostResult = Just requestToVolatileHostResult }
            in
            case maybeResponseFromVolatileHost of
                Nothing ->
                    ( setupStateWithScriptRunResult, Nothing )

                Just { fromHostResult, responseFromVolatileHost } ->
                    setupStateWithScriptRunResult
                        |> integrateResponseFromVolatileHost
                            { timeInMilliseconds = timeInMilliseconds
                            , responseFromVolatileHost = responseFromVolatileHost
                            , runInVolatileHostDurationInMs = fromHostResult.durationInMilliseconds
                            }

        InterfaceToHost.CompleteWithoutResult ->
            ( setupStateBefore, Nothing )


integrateResponseFromVolatileHost :
    { timeInMilliseconds : Int, responseFromVolatileHost : VolatileHostInterface.ResponseFromVolatileHost, runInVolatileHostDurationInMs : Int }
    -> SetupState
    -> ( SetupState, Maybe BotEvent )
integrateResponseFromVolatileHost { timeInMilliseconds, responseFromVolatileHost, runInVolatileHostDurationInMs } stateBefore =
    case responseFromVolatileHost of
        VolatileHostInterface.ListGameClientProcessesResponse gameClientProcesses ->
            ( { stateBefore | gameClientProcesses = Just gameClientProcesses }, Nothing )

        VolatileHostInterface.SearchUIRootAddressResult searchUIRootAddressResult ->
            let
                state =
                    { stateBefore | searchUIRootAddressResult = Just searchUIRootAddressResult }
            in
            ( state, Nothing )

        VolatileHostInterface.GetMemoryReadingResult getMemoryReadingResult ->
            let
                memoryReadingDurations =
                    runInVolatileHostDurationInMs
                        :: stateBefore.memoryReadingDurations
                        |> List.take 10

                state =
                    { stateBefore
                        | lastMemoryReading = Just { timeInMilliseconds = timeInMilliseconds, memoryReadingResult = getMemoryReadingResult }
                        , memoryReadingDurations = memoryReadingDurations
                    }

                maybeBotEvent =
                    case getMemoryReadingResult of
                        VolatileHostInterface.ProcessNotFound ->
                            Nothing

                        VolatileHostInterface.Completed completedMemoryReading ->
                            let
                                maybeParsedMemoryReading =
                                    completedMemoryReading.serialRepresentationJson
                                        |> Maybe.andThen (EveOnline.MemoryReading.decodeMemoryReadingFromString >> Result.toMaybe)
                                        |> Maybe.map (EveOnline.ParseUserInterface.parseUITreeWithDisplayRegionFromUITree >> EveOnline.ParseUserInterface.parseUserInterfaceFromUITree)
                            in
                            maybeParsedMemoryReading
                                |> Maybe.map MemoryReadingCompleted
            in
            ( state, maybeBotEvent )


type NextBotEffectFromQueue
    = NoEffect
    | ForwardEffect { newQueueState : BotEffectQueue, effect : BotEffect }


dequeueNextEffectFromBotState : { currentTimeInMs : Int } -> BotEffectQueue -> NextBotEffectFromQueue
dequeueNextEffectFromBotState { currentTimeInMs } effectQueueBefore =
    case effectQueueBefore of
        [] ->
            NoEffect

        nextEntry :: remainingEntries ->
            ForwardEffect
                { newQueueState = remainingEntries
                , effect = nextEntry.effect
                }


getNextSetupTask : SetupState -> SetupTask
getNextSetupTask stateBefore =
    case stateBefore.createVolatileHostResult of
        Nothing ->
            ContinueSetup
                stateBefore
                (InterfaceToHost.CreateVolatileHost { script = VolatileHostScript.setupScript })
                "Set up the volatile host. This can take several seconds, especially when assemblies are not cached yet."

        Just (Err error) ->
            FrameworkStopSession ("Create volatile host failed with exception: " ++ error.exceptionToString)

        Just (Ok createVolatileHostComplete) ->
            getSetupTaskWhenVolatileHostSetupCompleted stateBefore createVolatileHostComplete.hostId


getSetupTaskWhenVolatileHostSetupCompleted : SetupState -> InterfaceToHost.VolatileHostId -> SetupTask
getSetupTaskWhenVolatileHostSetupCompleted stateBefore volatileHostId =
    case stateBefore.searchUIRootAddressResult of
        Nothing ->
            case stateBefore.gameClientProcesses of
                Nothing ->
                    ContinueSetup stateBefore
                        (InterfaceToHost.RequestToVolatileHost
                            { hostId = volatileHostId
                            , request =
                                VolatileHostInterface.buildRequestStringToGetResponseFromVolatileHost
                                    VolatileHostInterface.ListGameClientProcessesRequest
                            }
                        )
                        "Get list of EVE Online client processes."

                Just gameClientProcesses ->
                    case gameClientProcesses |> selectGameClientProcess of
                        Err selectGameClientProcessError ->
                            FrameworkStopSession ("Failed to select the game client process: " ++ selectGameClientProcessError)

                        Ok gameClientSelection ->
                            ContinueSetup stateBefore
                                (InterfaceToHost.RequestToVolatileHost
                                    { hostId = volatileHostId
                                    , request =
                                        VolatileHostInterface.buildRequestStringToGetResponseFromVolatileHost
                                            (VolatileHostInterface.SearchUIRootAddress { processId = gameClientSelection.selectedProcess.processId })
                                    }
                                )
                                ((("Search the address of the UI root in process "
                                    ++ (gameClientSelection.selectedProcess.processId |> String.fromInt)
                                  )
                                    :: gameClientSelection.report
                                 )
                                    |> String.join "\n"
                                )

        Just searchResult ->
            case searchResult.uiRootAddress of
                Nothing ->
                    FrameworkStopSession ("Did not find the UI root in process " ++ (searchResult.processId |> String.fromInt))

                Just uiRootAddress ->
                    let
                        getMemoryReadingRequest =
                            VolatileHostInterface.GetMemoryReading { processId = searchResult.processId, uiRootAddress = uiRootAddress }
                    in
                    case stateBefore.lastMemoryReading of
                        Nothing ->
                            ContinueSetup stateBefore
                                (InterfaceToHost.RequestToVolatileHost
                                    { hostId = volatileHostId
                                    , request =
                                        VolatileHostInterface.buildRequestStringToGetResponseFromVolatileHost getMemoryReadingRequest
                                    }
                                )
                                "Get the first memory reading from the EVE Online client process. This can take several seconds."

                        Just lastMemoryReadingTime ->
                            case lastMemoryReadingTime.memoryReadingResult of
                                VolatileHostInterface.ProcessNotFound ->
                                    FrameworkStopSession "The EVE Online client process disappeared."

                                VolatileHostInterface.Completed lastCompletedMemoryReading ->
                                    let
                                        buildTaskFromRequestToVolatileHost requestToVolatileHost =
                                            InterfaceToHost.RequestToVolatileHost
                                                { hostId = volatileHostId
                                                , request = VolatileHostInterface.buildRequestStringToGetResponseFromVolatileHost requestToVolatileHost
                                                }
                                    in
                                    OperateBot
                                        { buildTaskFromBotEffect =
                                            \effect ->
                                                case effect of
                                                    EffectOnGameClientWindow effectOnWindow ->
                                                        { windowId = lastCompletedMemoryReading.mainWindowId
                                                        , task = effectOnWindow
                                                        , bringWindowToForeground = True
                                                        }
                                                            |> VolatileHostInterface.EffectOnWindow
                                                            |> buildTaskFromRequestToVolatileHost

                                                    EffectConsoleBeepSequence consoleBeepSequence ->
                                                        consoleBeepSequence
                                                            |> VolatileHostInterface.EffectConsoleBeepSequence
                                                            |> buildTaskFromRequestToVolatileHost
                                        , getMemoryReadingTask = getMemoryReadingRequest |> buildTaskFromRequestToVolatileHost
                                        , releaseVolatileHostTask = InterfaceToHost.ReleaseVolatileHost { hostId = volatileHostId }
                                        }


selectGameClientProcess :
    List VolatileHostInterface.GameClientProcessSummaryStruct
    -> Result String { selectedProcess : VolatileHostInterface.GameClientProcessSummaryStruct, report : List String }
selectGameClientProcess gameClientProcesses =
    case gameClientProcesses |> List.sortBy .mainWindowZIndex |> List.head of
        Nothing ->
            Err "I did not find an EVE Online client process."

        Just selectedProcess ->
            let
                report =
                    if [ selectedProcess ] == gameClientProcesses then
                        []

                    else
                        [ "I found "
                            ++ (gameClientProcesses |> List.length |> String.fromInt)
                            ++ " game client processes. I selected process "
                            ++ (selectedProcess.processId |> String.fromInt)
                            ++ " ('"
                            ++ selectedProcess.mainWindowTitle
                            ++ "') because its main window was the topmost."
                        ]
            in
            Ok { selectedProcess = selectedProcess, report = report }


requestToVolatileHostResultDisplayString : Result String InterfaceToHost.RequestToVolatileHostComplete -> { string : String, isErr : Bool }
requestToVolatileHostResultDisplayString result =
    case result of
        Err error ->
            { string = "Error: " ++ error, isErr = True }

        Ok runInVolatileHostComplete ->
            { string = "Success: " ++ (runInVolatileHostComplete.returnValueToString |> Maybe.withDefault "null"), isErr = False }


statusReportFromState : StateIncludingFramework s -> String
statusReportFromState state =
    let
        fromBot =
            state.botState.lastEvent
                |> Maybe.map
                    (\lastEvent ->
                        case lastEvent.eventResult |> Tuple.second of
                            FinishSession finishSession ->
                                finishSession.statusDescriptionText

                            ContinueSession continueSession ->
                                continueSession.statusDescriptionText
                    )
                |> Maybe.withDefault ""

        lastResultFromVolatileHost =
            "Last result from volatile host is: "
                ++ (state.setup.lastRequestToVolatileHostResult
                        |> Maybe.map requestToVolatileHostResultDisplayString
                        |> Maybe.map
                            (\resultDisplayInfo ->
                                resultDisplayInfo.string
                                    |> stringEllipsis
                                        (if resultDisplayInfo.isErr then
                                            640

                                         else
                                            140
                                        )
                                        "...."
                            )
                        |> Maybe.withDefault "Nothing"
                   )

        botEffectQueueLength =
            state.botState.effectQueue |> List.length

        memoryReadingDurations =
            state.setup.memoryReadingDurations
                -- Don't consider the first memory reading because it takes much longer.
                |> List.reverse
                |> List.drop 1

        averageMemoryReadingDuration =
            (memoryReadingDurations |> List.sum)
                // (memoryReadingDurations |> List.length)

        runtimeExpensesReport =
            "amrd=" ++ (averageMemoryReadingDuration |> String.fromInt) ++ "ms"

        botEffectQueueLengthWarning =
            if botEffectQueueLength < 4 then
                []

            else
                [ "Bot effect queue length is " ++ (botEffectQueueLength |> String.fromInt) ]
    in
    [ fromBot
    , "----"
    , "EVE Online framework status:"

    -- , runtimeExpensesReport
    , lastResultFromVolatileHost
    ]
        ++ botEffectQueueLengthWarning
        |> String.join "\n"


getEntropyIntFromUserInterface : EveOnline.ParseUserInterface.ParsedUserInterface -> Int
getEntropyIntFromUserInterface parsedUserInterface =
    let
        entropyFromString =
            Common.FNV.hashString

        entropyFromUiElement uiElement =
            [ uiElement.uiNode.pythonObjectAddress |> entropyFromString
            , uiElement.totalDisplayRegion.x
            , uiElement.totalDisplayRegion.y
            , uiElement.totalDisplayRegion.width
            , uiElement.totalDisplayRegion.height
            ]

        entropyFromOverviewEntry overviewEntry =
            (overviewEntry.cellsTexts |> Dict.values |> List.map entropyFromString)
                ++ (overviewEntry.uiNode |> entropyFromUiElement)

        entropyFromProbeScanResult probeScanResult =
            [ probeScanResult.uiNode |> entropyFromUiElement, probeScanResult.textsLeftToRight |> List.map entropyFromString ]
                |> List.concat

        fromMenus =
            parsedUserInterface.contextMenus
                |> List.concatMap (.entries >> List.map .uiNode)
                |> List.concatMap entropyFromUiElement

        fromOverview =
            parsedUserInterface.overviewWindow
                |> EveOnline.ParseUserInterface.maybeNothingFromCanNotSeeIt
                |> Maybe.map .entries
                |> Maybe.withDefault []
                |> List.concatMap entropyFromOverviewEntry

        fromProbeScanner =
            parsedUserInterface.probeScannerWindow
                |> EveOnline.ParseUserInterface.maybeNothingFromCanNotSeeIt
                |> Maybe.map .scanResults
                |> Maybe.withDefault []
                |> List.concatMap entropyFromProbeScanResult
    in
    (fromMenus ++ fromOverview ++ fromProbeScanner) |> List.sum


stringEllipsis : Int -> String -> String -> String
stringEllipsis howLong append string =
    if String.length string <= howLong then
        string

    else
        String.left (howLong - String.length append) string ++ append
