import Foundation

/// One audio rendition of the master the session serves, together with the
/// source track it carries - the answer to "which option of the player's audible
/// `AVMediaSelectionGroup` is track N?".
///
/// Why it exists: a host that lets the viewer pick an audio track has the
/// track (its own list, a media server's, the container's) and has to turn that
/// into an `AVMediaSelectionOption`. The only thing the group's options carry
/// that a host could compare is a language tag, and a language is not an
/// identity: two tracks of one language (a stereo mix and a 5.1 one, a
/// commentary) are two options that match the same tag, and a track with no tag
/// at all matches nothing. A host that selects "the first option of the
/// language" plays the wrong track for the first case and cannot pick the second
/// at all. The master this session writes already gives every option a name that
/// is unique within the group (`AudioRenditionWriter.uniqueRenditionNames`:
/// the container's own title, else the language spelled out, else "Audio N",
/// numbered where two would collide) - this list says which name belongs to
/// which source stream, so that the host selects the option that carries `name`.
///
/// **How a host reads an option's name - and what it must not use.** AVFoundation
/// hands the `NAME` of an `EXT-X-MEDIA` line to the option as its `title`
/// common-metadata item (`option.commonMetadata`, `commonKey == .commonKeyTitle`,
/// identifier `m3u8/NAME`) - the way `AVMediaSelectionGroup.h` documents for
/// reading an option's name. `displayName` is NOT the NAME: AVFoundation builds it
/// from the option's language, locale and characteristics, and takes a name from
/// the metadata only when that item is authored in the system's locale. Measured
/// on macOS 27 in a process with a German locale: two options with
/// `LANGUAGE="eng"` and the NAMEs "English" and "Englisch" are both "English",
/// an option for `LANGUAGE="ces"` named "Tschechisch" is "Czech", and an option
/// with no `LANGUAGE` named "Audio 2" is "Unknown" ("Unbekannt" in German). A host
/// that compares `displayName` with `name` finds nothing, or the wrong option.
///
/// What it is, exactly:
///
/// - `streamIndex` is `AudioTrackInfo.streamIndex` - the container's own index of
///   the stream, which is also the number media servers report for it (ffprobe's
///   `Stream #0:N`, Jellyfin's `MediaStream.Index`).
/// - `name` is the `NAME` the master declares, character for character as the
///   playlist prints it (a double quote in a container title is folded to a
///   single quote there, and here): the text of the matching option's `title`
///   metadata item. It is what a host compares, never something it parses: the
///   text is the container's title or a localized language name. Within the
///   master the names are unique (`uniqueRenditionNames`); the one way two can
///   still print alike is the quote fold (`A"B` and `A'B`), and a host that wants
///   to be exact there pairs the k-th option of a name with the k-th entry of that
///   name - AVFoundation lists the options in the master's order, as this list is
///   (seen on macOS 27).
/// - `language` is the `LANGUAGE` the master declares for it - the container's
///   tag, verbatim (`ger`, `ces`, `pt-BR`) - or `nil` when the container has none
///   (or says `und`, which is no language). For display and for a fallback
///   comparison, not for identifying the track.
/// - `isDefault` is the rendition flagged `DEFAULT`: the track `chooseAudio`
///   would have played (the host's `preferredAudioLanguage` first), the first
///   one of the list.
///
/// What it is not: tracks the master does not carry are not in it (a codec this
/// build can neither copy nor bridge is left out of the master, and so is out of
/// the list); neither are the dialogue-boost renditions, which share the stream
/// of the base rendition they are derived from and are reported by
/// `PrismCoreSession.dialogueBoostRenditions`. The list is in the order of the
/// master (the `DEFAULT` track first, then the container's order).
public struct AudioRenditionInfo: Sendable, Equatable {
    public let streamIndex: Int
    public let name: String
    public let language: String?
    public let isDefault: Bool

    public init(streamIndex: Int, name: String, language: String?, isDefault: Bool) {
        self.streamIndex = streamIndex
        self.name = name
        self.language = language
        self.isDefault = isDefault
    }
}
