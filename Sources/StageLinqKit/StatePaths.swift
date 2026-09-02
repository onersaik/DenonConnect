// StatePaths.swift
// Lista completa y verificada de rutas StateMap que expone Engine OS,
// extraída directamente del enum StageLinqValue de la librería de referencia
// https://github.com/chrisle/StageLinq (types/common.ts). 47 rutas por deck
// (incluyendo QuickLoop1-8) más las rutas globales de mezclador/cliente/master.

import Foundation

public enum StatePaths {
    /// Sufijos relativos a "/Engine/DeckN" (N = 1..4). 47 por deck.
    public static let perDeckSuffixes: [String] = [
        "/CurrentBPM",
        "/ExternalMixerVolume",
        "/ExternalScratchWheelTouch",
        "/Pads/View",
        "/Play",
        "/PlayState",
        "/PlayStatePath",
        "/Speed",
        "/SpeedNeutral",
        "/SpeedOffsetDown",
        "/SpeedOffsetUp",
        "/SpeedRange",
        "/SpeedState",
        "/SyncMode",
        "/Track/ArtistName",
        "/Track/Bleep",
        "/Track/CuePosition",
        "/Track/CurrentBPM",
        "/Track/CurrentKey",
        "/Track/CurrentKeyIndex",
        "/Track/CurrentLoopInPosition",
        "/Track/CurrentLoopOutPosition",
        "/Track/CurrentLoopSizeInBeats",
        "/Track/Genre",
        "/Track/KeyLock",
        "/Track/Loop/QuickLoop1",
        "/Track/Loop/QuickLoop2",
        "/Track/Loop/QuickLoop3",
        "/Track/Loop/QuickLoop4",
        "/Track/Loop/QuickLoop5",
        "/Track/Loop/QuickLoop6",
        "/Track/Loop/QuickLoop7",
        "/Track/Loop/QuickLoop8",
        "/Track/LoopEnableState",
        "/Track/PlayPauseLEDState",
        "/Track/SampleRate",
        "/Track/SongAnalyzed",
        "/Track/SongLoaded",
        "/Track/SongName",
        "/Track/SoundSwitchGuid",
        "/Track/TrackBytes",
        "/Track/TrackData",
        "/Track/TrackLength",
        "/Track/TrackName",
        "/Track/TrackNetworkPath",
        "/Track/TrackUri",
        "/Track/TrackWasPlayed",
    ]

    /// DeckIsMaster solo existe para Deck1/Deck2 (concepto de reproductor físico,
    /// no de capa), y vive bajo /Client/ en vez de /Engine/.
    public static func deckIsMasterPath(deck: Int) -> String? {
        guard deck == 1 || deck == 2 else { return nil }
        return "/Client/Deck\(deck)/DeckIsMaster"
    }

    /// Rutas globales, no específicas de un deck.
    public static let globalPaths: [String] = [
        "/Client/Librarian/DevicesController/CurrentDevice",
        "/Client/Librarian/DevicesController/HasSDCardConnected",
        "/Client/Librarian/DevicesController/HasUsbDeviceConnected",
        "/Client/Preferences/LayerA",
        "/Client/Preferences/LayerB",
        "/Client/Preferences/Player",
        "/Client/Preferences/PlayerJogColorA",
        "/Client/Preferences/PlayerJogColorB",
        "/Client/Preferences/Profile/Application/PlayerColor1",
        "/Client/Preferences/Profile/Application/PlayerColor1A",
        "/Client/Preferences/Profile/Application/PlayerColor1B",
        "/Client/Preferences/Profile/Application/PlayerColor2",
        "/Client/Preferences/Profile/Application/PlayerColor2A",
        "/Client/Preferences/Profile/Application/PlayerColor2B",
        "/Client/Preferences/Profile/Application/PlayerColor3",
        "/Client/Preferences/Profile/Application/PlayerColor3A",
        "/Client/Preferences/Profile/Application/PlayerColor3B",
        "/Client/Preferences/Profile/Application/PlayerColor4",
        "/Client/Preferences/Profile/Application/PlayerColor4A",
        "/Client/Preferences/Profile/Application/PlayerColor4B",
        "/Client/Preferences/Profile/Application/SyncMode",
        "/Engine/DeckCount",
        "/Engine/Master/MasterTempo",
        "/Engine/Sync/Network/MasterStatus",
        "/GUI/Decks/Deck/ActiveDeck",
        "/GUI/ViewLayer/LayerB",
        "/Mixer/CH1faderPosition",
        "/Mixer/CH2faderPosition",
        "/Mixer/CH3faderPosition",
        "/Mixer/CH4faderPosition",
        "/Mixer/ChannelAssignment1",
        "/Mixer/ChannelAssignment2",
        "/Mixer/ChannelAssignment3",
        "/Mixer/ChannelAssignment4",
        "/Mixer/CrossfaderPosition",
        "/Mixer/NumberOfChannels",
    ]

    /// Todas las rutas a suscribir para un dispositivo con 4 decks lógicos.
    public static func allPaths() -> [String] {
        var paths: [String] = []
        for deck in 1...4 {
            let prefix = "/Engine/Deck\(deck)"
            for suffix in perDeckSuffixes {
                paths.append(prefix + suffix)
            }
            if let masterPath = deckIsMasterPath(deck: deck) {
                paths.append(masterPath)
            }
        }
        paths.append(contentsOf: globalPaths)
        return paths
    }
}
