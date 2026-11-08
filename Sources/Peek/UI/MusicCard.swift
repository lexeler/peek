import SwiftUI

struct MusicCard: View {
    @Environment(NowPlayingService.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 0) {
                if let track = player.track {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist.isEmpty ? " " : track.artist)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 1)
                    Spacer(minLength: 2)
                    controls(playing: track.playing)
                    ProgressLine(track: track)
                        .padding(.top, 6)
                } else {
                    Text("Тишина")
                        .font(.system(size: 13, weight: .semibold))
                    Text(player.isAvailable ? "Сейчас ничего не играет" : "Плеер недоступен")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    Spacer(minLength: 2)
                    Button(action: player.openPlayer) {
                        Label("Яндекс Музыка", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.smooth(duration: 0.25), value: player.track?.title)
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return ZStack {
            if let image = player.artwork {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.06)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
        .animation(.smooth(duration: 0.35), value: player.artwork.map { ObjectIdentifier($0) })
        .onTapGesture(perform: player.openPlayer)
        .help("Открыть плеер")
    }

    private func controls(playing: Bool) -> some View {
        HStack(spacing: 14) {
            IconButton(symbol: "backward.fill", size: 12.5, action: player.previous)
            IconButton(symbol: playing ? "pause.fill" : "play.fill", size: 17, frame: 30,
                       action: player.togglePlayPause)
            IconButton(symbol: "forward.fill", size: 12.5, action: player.next)
        }
        .padding(.leading, -6)
    }
}

/// Thin progress line. Ticks once per second only while the panel is open and music plays.
private struct ProgressLine: View {
    let track: NowPlayingService.Track

    var body: some View {
        if track.duration > 0 {
            if track.playing {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    bar(fraction: track.elapsed(at: context.date) / track.duration)
                }
            } else {
                bar(fraction: track.elapsed / track.duration)
            }
        } else {
            Color.clear.frame(height: 3)
        }
    }

    private func bar(fraction: Double) -> some View {
        let clamped = min(max(fraction, 0), 1)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                Capsule().fill(Color.primary.opacity(0.75))
                    .frame(width: max(3, proxy.size.width * clamped))
            }
        }
        .frame(height: 3)
        // No implicit animation: a 1 s linear glide would chain into continuous 120 Hz redraws of the
        // glass while music plays. One discrete step per second is invisible at this size and ~free.
    }
}
