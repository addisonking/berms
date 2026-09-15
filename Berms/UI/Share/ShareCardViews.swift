import SwiftUI

struct ShareCardCanvas: View {
    let content: ShareCardContent
    let configuration: ShareCardConfiguration
    let mapImage: UIImage?

    var body: some View {
        let palette = ShareCardPalette.of(configuration.preset)
        Group {
            switch configuration.preset {
            case .story:
                ShareCardStoryLayout(content: content, configuration: configuration,
                                     mapImage: mapImage, palette: palette)
            case .post:
                ShareCardPostLayout(content: content, configuration: configuration,
                                    mapImage: mapImage, palette: palette)
            case .portrait:
                ShareCardPortraitLayout(content: content, configuration: configuration,
                                        mapImage: mapImage, palette: palette)
            }
        }
        .frame(width: configuration.preset.canvasSize.width,
               height: configuration.preset.canvasSize.height)
        .clipped()
    }
}

private struct ShareCardStoryLayout: View {
    let content: ShareCardContent
    let configuration: ShareCardConfiguration
    let mapImage: UIImage?
    let palette: ShareCardPalette

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            palette.background
            if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .scaledToFill()
            }
            scrim
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 0)
                stats
                if configuration.showsWatermark {
                    ShareCardWatermark(tint: palette.watermark)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 18)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 22)
        }
    }

    private var scrim: some View {
        LinearGradient(stops: [
            .init(color: palette.scrim.opacity(0.55), location: 0),
            .init(color: palette.scrim.opacity(0), location: 0.26),
            .init(color: palette.scrim.opacity(0), location: 0.46),
            .init(color: palette.scrim.opacity(0.86), location: 1)
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(content.title)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(content.meta)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    @ViewBuilder
    private var stats: some View {
        let hero = content.stats.first { $0.kind == .descent } ?? content.stats.first
        let small = content.stats.filter { $0.id != hero?.id }.prefix(3)
        VStack(alignment: .leading, spacing: 12) {
            if let hero {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hero.value)
                        .font(.system(size: 58, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(hero.shortTitle)
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(palette.secondaryText)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hero.title)
                .accessibilityValue(hero.value)
            }
            HStack(alignment: .top, spacing: 22) {
                ForEach(Array(small)) { stat in
                    ShareCardStatView(stat: stat,
                                      valueSize: 19,
                                      labelSize: 9.5,
                                      valueColor: palette.primaryText,
                                      labelColor: palette.secondaryText)
                }
            }
        }
    }
}

private struct ShareCardPostLayout: View {
    let content: ShareCardContent
    let configuration: ShareCardConfiguration
    let mapImage: UIImage?
    let palette: ShareCardPalette

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                palette.background
                if let mapImage {
                    Image(uiImage: mapImage)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(height: configuration.preset.mapFrameSize.height)
            .clipped()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 14)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(content.stats) { stat in
                        ShareCardStatView(stat: stat,
                                          valueSize: 19,
                                          labelSize: 9,
                                          valueColor: palette.primaryText,
                                          labelColor: palette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
                if configuration.showsWatermark {
                    ShareCardWatermark(tint: palette.watermark)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(height: configuration.preset.canvasSize.height - configuration.preset.mapFrameSize.height)
            .background(palette.panel)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(content.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(content.meta)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct ShareCardPortraitLayout: View {
    let content: ShareCardContent
    let configuration: ShareCardConfiguration
    let mapImage: UIImage?
    let palette: ShareCardPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 16)
            if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: configuration.preset.mapFrameSize.width,
                           height: configuration.preset.mapFrameSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.bottom, 14)
            }
            VStack(spacing: 0) {
                ForEach(Array(content.stats.enumerated()), id: \.element.id) { index, stat in
                    HStack(alignment: .firstTextBaseline) {
                        Text(stat.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.secondaryText)
                        Spacer(minLength: 12)
                        Text(stat.value)
                            .font(.system(size: 16, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(palette.primaryText)
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(stat.title)
                    .accessibilityValue(stat.value)
                    if index < content.stats.count - 1 {
                        Rectangle()
                            .fill(palette.primaryText.opacity(0.08))
                            .frame(height: 1)
                    }
                }
            }
            Spacer(minLength: 0)
            if configuration.showsWatermark {
                ShareCardWatermark(tint: palette.watermark)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(content.title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(content.meta)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct ShareCardStatView: View {
    let stat: ShareCardStat
    let valueSize: CGFloat
    let labelSize: CGFloat
    let valueColor: Color
    let labelColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(stat.value)
                .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(stat.shortTitle)
                .font(.system(size: labelSize, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stat.title)
        .accessibilityValue(stat.value)
    }
}

struct ShareCardWatermark: View {
    var tint: Color
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "mountain.2.fill")
                .font(.system(size: size * 0.9, weight: .semibold))
            Text("Berms")
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .tracking(0.2)
        }
        .foregroundStyle(tint)
        .opacity(0.55)
        .accessibilityHidden(true)
    }
}
