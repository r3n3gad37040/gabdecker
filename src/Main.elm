----------------------------------------------------------------------
--
-- example.elm
-- Example of using the Gab API client.
-- Copyright (c) 2017-2018 Bill St. Clair <billstclair@gmail.com>
-- Some rights reserved.
-- Distributed under the MIT License
-- See LICENSE.txt
--
-- Search for TODO to see remaining work.
--
----------------------------------------------------------------------


module Main exposing (main)

import Browser exposing (Document, UrlRequest(..))
import Browser.Dom as Dom exposing (Viewport)
import Browser.Events as Events
import Browser.Navigation as Navigation exposing (Key)
import Char
import Cmd.Extra exposing (withCmd, withCmds, withNoCmd)
import CustomElement.FileListener as File exposing (File)
import Dict exposing (Dict)
import Element
    exposing
        ( Attribute
        , Color
        , Element
        , centerX
        , column
        , el
        , height
        , image
        , link
        , padding
        , paragraph
        , px
        , row
        , spacing
        , text
        , textColumn
        , width
        )
import Element.Border as Border
import Element.Font as Font
import Gab
import Gab.EncodeDecode as ED
import Gab.Types
    exposing
        ( ActivityLog
        , ActivityLogList
        , Post
        , PostForm
        , RequestParts
        , SavedToken
        , User
        )
import GabDecker.Api as Api exposing (Backend(..))
import GabDecker.Types as Types exposing (Feed, FeedGetter(..), FeedType(..))
import Http
import Json.Decode as JD exposing (Decoder, Value)
import Json.Encode as JE
import List.Extra as LE
import OAuth exposing (Token(..))
import OAuthMiddleware
    exposing
        ( Authorization
        , ResponseToken
        , TokenAuthorization
        , TokenState(..)
        , authorize
        , getAuthorization
        , locationToRedirectBackUri
        , receiveTokenAndState
        , use
        )
import OAuthMiddleware.EncodeDecode
    exposing
        ( authorizationEncoder
        , responseTokenEncoder
        )
import PortFunnel.LocalStorage as LocalStorage
import PortFunnels exposing (FunnelDict, Handler(..))
import String
import String.Extra as SE
import Task
import Time exposing (Posix)
import Url exposing (Url)


allScopes : List ( String, String )
allScopes =
    [ ( "Read", "read" )
    , ( "Engage User", "engage-user" )
    , ( "Engage Post", "engage-post" )
    , ( "Post", "write-post" )
    , ( "Notifications", "notifications" )
    ]


type alias Model =
    { useSimulator : Bool
    , windowHeight : Int
    , backend : Maybe Backend
    , key : Key
    , funnelState : PortFunnels.State
    , token : Maybe SavedToken
    , state : Maybe String
    , msg : Maybe String
    , loggedInUser : Maybe String
    , replyType : String
    , reply : Maybe Value
    , redirectBackUri : String
    , authorization : Maybe Authorization
    , scopes : List String
    , receivedScopes : List String
    , tokenAuthorization : Maybe TokenAuthorization
    , username : String
    , feeds : List (Feed Msg)
    }


type UploadingState
    = NotUploading
    | Uploading
    | FinishedUploading String
    | ErrorUploading String


type Msg
    = HandleUrlRequest UrlRequest
    | HandleUrlChange Url
    | ReceiveAuthorization (Result Http.Error Authorization)
    | ReceiveLoggedInUser (Result Http.Error User)
    | PersistResponseToken ResponseToken Posix
    | ProcessLocalStorage Value
    | WindowResize Int Int
    | ReceiveFeed FeedType (Result Api.Error ActivityLogList)


{-| GitHub requires the "User-Agent" header.
-}
userAgentHeader : Http.Header
userAgentHeader =
    Http.header "User-Agent" "GabDecker"


main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        , onUrlRequest = HandleUrlRequest
        , onUrlChange = HandleUrlChange
        }


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ PortFunnels.subscriptions ProcessLocalStorage model
        , Events.onResize WindowResize
        ]


localStoragePrefix : String
localStoragePrefix =
    "gab-api-example"


init : Value -> Url -> Key -> ( Model, Cmd Msg )
init flags url key =
    let
        tokenAndState =
            receiveTokenAndState url

        nono =
            ( Nothing, Nothing )

        ( ( token, savedToken ), state, msg ) =
            case tokenAndState of
                TokenAndState tok stat ->
                    let
                        st =
                            Gab.savedTokenFromResponseToken
                                (Time.millisToPosix 0)
                                tok
                    in
                    ( ( Just tok, Just st ), stat, Nothing )

                TokenErrorAndState m stat ->
                    ( nono, stat, Just m )

                TokenDecodeError m ->
                    ( nono, Nothing, Just m )

                NoToken ->
                    ( nono, Nothing, Nothing )

        ( reply, scopes ) =
            case token of
                Nothing ->
                    ( Nothing, [ "read" ] )

                Just tok ->
                    ( Just <| responseTokenEncoder tok
                    , tok.scope
                    )

        model =
            let
                useSimulator =
                    JE.encode 0 flags == "undefined"

                backend =
                    if useSimulator then
                        Just SimulatedBackend

                    else
                        Nothing
            in
            { useSimulator = useSimulator
            , backend = backend
            , key = key
            , windowHeight = 1024
            , funnelState = PortFunnels.initialState localStoragePrefix
            , token = savedToken
            , state = state
            , msg = msg
            , loggedInUser = Nothing
            , replyType = "Token"
            , reply = reply
            , redirectBackUri = locationToRedirectBackUri url
            , authorization = Nothing
            , scopes = scopes
            , receivedScopes = scopes
            , tokenAuthorization = Nothing
            , username = "xossbow"
            , feeds =
                feedTypesToFeeds
                    [ HomeFeed, UserFeed "a", PopularFeed ]
                    backend
            }
    in
    model
        |> withCmds
            [ Http.send ReceiveAuthorization <|
                getAuthorization False "authorization.json"
            , Navigation.replaceUrl key "#"
            , case token of
                Just t ->
                    Task.perform (PersistResponseToken t) Time.now

                Nothing ->
                    if tokenAndState == NoToken then
                        localStorageSend (LocalStorage.get tokenKey) model

                    else
                        Cmd.none
            , Task.perform getViewport Dom.getViewport
            , Cmd.batch <|
                List.map feedGetMore model.feeds
            ]


getViewport : Viewport -> Msg
getViewport viewport =
    let
        vp =
            viewport.viewport
    in
    WindowResize (round vp.width) (round vp.height)


feedTypesToFeeds : List FeedType -> Maybe Backend -> List (Feed Msg)
feedTypesToFeeds feedTypes maybeBackend =
    case maybeBackend of
        Nothing ->
            []

        Just backend ->
            List.map (feedTypeToFeed backend) feedTypes


columnWidth : Int
columnWidth =
    250


feedTypeToFeed : Backend -> FeedType -> Feed Msg
feedTypeToFeed backend feedType =
    { getter = Types.feedTypeToGetter feedType backend (ReceiveFeed feedType)
    , feedType = feedType
    , description = feedTypeDescription feedType
    , feed = { data = [], no_more = False }
    , error = Nothing
    , columnWidth = columnWidth
    }


feedTypeDescription : FeedType -> String
feedTypeDescription feedType =
    case feedType of
        HomeFeed ->
            "Home"

        UserFeed user ->
            "User: " ++ user

        -- Need to look up group name
        GroupFeed groupid ->
            "Group: " ++ groupid

        -- Need to look up topic name
        TopicFeed groupid ->
            "Topic: " ++ groupid

        PopularFeed ->
            "Popular"


feedGetMore : Feed Msg -> Cmd Msg
feedGetMore feed =
    if feed.feed.no_more then
        Cmd.none

    else
        case feed.getter of
            FeedGetter cmd ->
                cmd

            FeedGetterWithBefore f ->
                let
                    before =
                        case LE.last feed.feed.data of
                            Nothing ->
                                ""

                            Just log ->
                                log.published_at
                in
                f before


storageHandler : LocalStorage.Response -> PortFunnels.State -> Model -> ( Model, Cmd Msg )
storageHandler response state model =
    case response of
        LocalStorage.GetResponse { key, value } ->
            if key /= tokenKey then
                model |> withNoCmd

            else
                case value of
                    Nothing ->
                        model |> withNoCmd

                    Just v ->
                        case JD.decodeValue ED.savedTokenDecoder v of
                            Err err ->
                                { model | msg = Just <| JD.errorToString err }
                                    |> withNoCmd

                            Ok savedToken ->
                                ( { model
                                    | token = Just savedToken
                                    , scopes = savedToken.scope
                                    , receivedScopes = savedToken.scope
                                  }
                                , Http.send ReceiveLoggedInUser <|
                                    Gab.me savedToken.token
                                )

        _ ->
            model |> withNoCmd


{-| TODO: add checkboxes to UI to select scopes.
-}
lookupProvider : Model -> Model
lookupProvider model =
    case model.authorization of
        Nothing ->
            model

        Just auth ->
            { model
                | tokenAuthorization =
                    Just
                        { authorization = auth

                        -- This will be overridden by the user checkboxes
                        , scope = List.map Tuple.second <| Dict.toList auth.scopes
                        , state = Nothing
                        , redirectBackUri = model.redirectBackUri
                        }
            }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        HandleUrlRequest request ->
            ( model
            , case request of
                Internal url ->
                    -- For now
                    Navigation.load <| Url.toString url

                External urlString ->
                    Navigation.load urlString
            )

        HandleUrlChange url ->
            model |> withNoCmd

        ReceiveAuthorization result ->
            case result of
                Err err ->
                    { model | msg = Just <| Debug.toString err }
                        |> withNoCmd

                Ok authorization ->
                    let
                        ( replyType, reply ) =
                            case ( model.reply, model.msg ) of
                                ( Nothing, Nothing ) ->
                                    ( "Authorization"
                                    , Just <|
                                        authorizationEncoder
                                            { authorization
                                                | clientId = "not telling"
                                                , redirectUri = "don't ask"
                                            }
                                    )

                                _ ->
                                    ( model.replyType
                                    , model.reply
                                    )
                    in
                    lookupProvider
                        { model
                            | authorization = Just authorization
                            , scopes =
                                if model.token == Nothing then
                                    List.map Tuple.second <| Dict.toList authorization.scopes

                                else
                                    model.scopes
                            , replyType = replyType
                            , reply = reply
                        }
                        |> withCmd
                            (case model.token of
                                Nothing ->
                                    Cmd.none

                                Just token ->
                                    Http.send ReceiveLoggedInUser <|
                                        Gab.me token.token
                            )

        ReceiveLoggedInUser result ->
            case result of
                Err _ ->
                    { model | msg = Just "Error getting logged-in user name." }
                        |> withNoCmd

                Ok user ->
                    { model | loggedInUser = Just user.username }
                        |> withNoCmd

        PersistResponseToken token time ->
            let
                value =
                    Gab.savedTokenFromResponseToken time token
                        |> ED.savedTokenEncoder
            in
            ( model
            , localStorageSend
                (LocalStorage.put tokenKey <| Just value)
                model
            )

        ProcessLocalStorage value ->
            case
                PortFunnels.processValue funnelDict
                    value
                    model.funnelState
                    model
            of
                Err error ->
                    { model | msg = Just error } |> withNoCmd

                Ok res ->
                    res

        WindowResize _ h ->
            { model | windowHeight = h } |> withNoCmd

        ReceiveFeed feedType result ->
            { model | feeds = updateFeeds feedType result model.feeds }
                |> withNoCmd


updateFeeds : FeedType -> Result Api.Error ActivityLogList -> List (Feed Msg) -> List (Feed Msg)
updateFeeds feedType result feeds =
    let
        loop tail res =
            case tail of
                [] ->
                    List.reverse res

                feed :: rest ->
                    if feed.feedType == feedType then
                        List.concat
                            [ List.reverse res
                            , [ updateFeed result feed ]
                            , rest
                            ]

                    else
                        loop rest (feed :: res)
    in
    loop feeds []


updateFeed : Result Api.Error ActivityLogList -> Feed Msg -> Feed Msg
updateFeed result feed =
    case result of
        Err err ->
            { feed | error = Just err }

        Ok activities ->
            { feed
                | error = Nothing
                , feed =
                    { data = List.append feed.feed.data activities.data
                    , no_more = activities.no_more
                    }
            }


tokenKey : String
tokenKey =
    "token"


funnelDict : FunnelDict Model Msg
funnelDict =
    PortFunnels.makeFunnelDict [ LocalStorageHandler storageHandler ] getCmdPort


getCmdPort : String -> Model -> (Value -> Cmd Msg)
getCmdPort moduleName model =
    PortFunnels.getCmdPort ProcessLocalStorage moduleName False


localStorageSend : LocalStorage.Message -> Model -> Cmd Msg
localStorageSend message model =
    LocalStorage.send (getCmdPort LocalStorage.moduleName model)
        message
        model.funnelState.storage


pageTitle : String
pageTitle =
    "GabDecker"


view : Model -> Document Msg
view model =
    { title = pageTitle
    , body = [ Element.layout [] <| pageBody model ]
    }


itou : Int -> Float
itou i =
    toFloat i / 255


rgbi : Int -> Int -> Int -> Color
rgbi r g b =
    Element.rgb (itou r) (itou g) (itou b)


lightBlue : Color
lightBlue =
    rgbi 0xAD 0xD8 0xE6


blue : Color
blue =
    Element.rgb 0 0 1


{-| Color highlighting is temporary, until Font.underline becomes decorative.
-}
simpleLink : String -> String -> Element msg
simpleLink url label =
    link
        [ Font.color blue
        , Element.mouseOver [ Font.color lightBlue ]
        ]
        { url = url
        , label = text label
        }


simpleImage : String -> String -> ( Int, Int ) -> Element msg
simpleImage src description ( w, h ) =
    image
        [ width (px w)
        , height (px h)
        ]
        { src = src
        , description = description
        }


baseFontSize : Float
baseFontSize =
    12


fontSize : Float -> Element.Attr decorative msg
fontSize scale =
    Font.size <| round (scale * baseFontSize)


pageBody : Model -> Element Msg
pageBody model =
    case model.backend of
        Nothing ->
            loginPage model

        Just _ ->
            mainPage model


fillWidth : Attribute msg
fillWidth =
    width Element.fill


mainPage : Model -> Element Msg
mainPage model =
    row
        [ fillWidth
        , height Element.fill
        , fontSize 1
        ]
    <|
        List.map (feedColumn model.windowHeight) model.feeds


zeroes =
    { right = 0
    , left = 0
    , top = 0
    , bottom = 0
    }


{-| 20 has no rhyme or reason other than it works.
-}
headerHeight : Int
headerHeight =
    (round <| 1.5 * baseFontSize) + 20


feedColumn : Int -> Feed Msg -> Element Msg
feedColumn windowHeight feed =
    let
        colw =
            width <| px feed.columnWidth
    in
    column
        [ colw
        , height Element.fill
        , Border.width 1
        ]
        [ row
            [ fillWidth
            , Border.widthEach { zeroes | bottom = 1 }
            ]
            [ column [ colw ]
                [ row
                    [ padding 10
                    , fontSize 1.5
                    , Font.bold
                    , centerX
                    ]
                    [ text feed.description ]
                ]
            ]
        , row []
            [ column
                [ colw

                -- This needs to be the adjusted window height, not 1024
                , height <| px (windowHeight - headerHeight)
                , Element.scrollbarX
                ]
              <|
                List.map (postRow feed.columnWidth) feed.feed.data
            ]
        ]


userPadding : Attribute msg
userPadding =
    Element.paddingEach
        { top = 0
        , right = 0
        , bottom = 4
        , left = 0
        }


postBorder : Attribute msg
postBorder =
    Border.widthEach
        { bottom = 1
        , left = 0
        , right = 0
        , top = 1
        }


postRow : Int -> ActivityLog -> Element Msg
postRow cw log =
    let
        pad =
            5

        colw =
            width <| px (cw - 2 * pad)

        actuser =
            log.actuser
    in
    row
        [ postBorder
        , fillWidth
        , padding pad
        ]
        [ column [ colw ]
            [ row
                [ Font.bold
                , userPadding
                ]
                [ text actuser.name
                , text " ("
                , text actuser.username
                , text ")"
                ]
            , row
                []
                [ Element.textColumn
                    [ colw ]
                    [ paragraph
                        [ Element.clipY ]
                        [ text <|
                            case log.post.body_html of
                                Nothing ->
                                    log.post.body

                                Just html ->
                                    html
                        ]
                    ]
                ]
            ]
        ]


loginPage : Model -> Element Msg
loginPage model =
    row
        [ fillWidth
        , fontSize 2
        ]
        [ column [ centerX, spacing 10 ]
            [ row
                [ centerX
                , padding 20
                , fontSize 3
                , Font.bold
                ]
                [ text "GabDecker" ]
            , row [ centerX ]
                [ simpleLink "./" "GabDecker"
                , text " is a "
                , simpleLink "https://tweetdeck.twitter.com" "TweetDeck"
                , text "-like interface to "
                , simpleLink "https://gab.com" "Gab.com"
                , text "."
                ]
            , row [ centerX ]
                [ simpleImage "images/deck-with-frog-671x425.jpg"
                    "Deck with Frog"
                    ( 671, 425 )
                ]
            , row [ centerX ]
                [ simpleLink "news/" "News" ]
            , row [ centerX ]
                [ simpleLink "api/" "Gab API Explorer" ]
            , row [ centerX ]
                [ column [ centerX, spacing 6, fontSize 1.5 ]
                    [ row [ centerX ]
                        [ text <| copyright ++ " 2018 Bill St. Clair" ]
                    , row [ centerX ]
                        [ simpleLink "https://github.com/melon-love/gabdecker"
                            "GitHub"
                        ]
                    ]
                ]
            ]
        ]


copyright : String
copyright =
    String.fromList [ Char.fromCode 0xA9 ]
