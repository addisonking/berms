import MapKit
import SwiftData
import SwiftUI
import UIKit

struct MapControlStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GlassEffectContainer(spacing: BermsSpacing.compact) {
            VStack(spacing: BermsSpacing.compact) { content }
        }
    }
}

struct MapActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.headline)
                .frame(minWidth: BermsSpacing.target, minHeight: BermsSpacing.target)
        }
        .bermsMapControl()
    }
}

struct MapRecenterButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let action: () -> Void

    var body: some View {
        MapActionButton(title: "Show entire route", systemImage: "scope") {
            withAnimation(reduceMotion ? nil : BermsMotion.recenter, action)
        }
    }
}

struct MapLayersMenu: View {
    @ObservedObject var preferences: MapLayerPreferences
    var showsRidePathControl = true
    var showsActualTrailsControl = true
    var actualTrailsAvailable = true
    var showsJumpsControl = true
    var showsLiftPathsControl = false
    var liftPathsAvailable = true
    var showsPreviousRunsControl = false

    var body: some View {
        Menu {
            if showsRidePathControl {
                Toggle("Ride path", isOn: $preferences.showsRidePath)
            }
            if showsActualTrailsControl {
                Toggle("Actual trails", isOn: $preferences.showsActualTrails)
                    .disabled(!actualTrailsAvailable)
            }
            if showsJumpsControl {
                Toggle("Jumps", isOn: $preferences.showsJumps)
            }
            if showsLiftPathsControl {
                Toggle("Lift paths", isOn: $preferences.showsLiftPaths)
                    .disabled(!liftPathsAvailable)
            }
            if showsPreviousRunsControl {
                Toggle("Previous runs", isOn: $preferences.showsPreviousRunsInLiveMap)
            }
        } label: {
            Label("Layers", systemImage: "square.3.layers.3d")
                .labelStyle(.iconOnly)
                .font(.headline)
                .frame(minWidth: BermsSpacing.target, minHeight: BermsSpacing.target)
        }
        .bermsMapControl()
        .accessibilityLabel("Map layers")
    }
}

struct RunNumberMarker: View {
    let number: Int
    let isSelected: Bool
    @ScaledMetric(relativeTo: .caption) private var markerSize: CGFloat = 26

    var body: some View {
        Text("\(number)")
            .font(.caption.weight(.heavy))
            .foregroundStyle(isSelected ? Color.bermsOnAccent : Color.bermsTrail)
            .frame(width: markerSize, height: markerSize)
            .background(isSelected ? Color.bermsTrail : Color.bermsCard, in: Circle())
            .overlay(Circle().stroke(Color.bermsTrail, lineWidth: 1.5))
            .accessibilityLabel("Run \(number)")
    }
}

struct JumpMapMarker: View {
    let number: Int
    let airtime: TimeInterval
    var showsAirtime = false
    @ScaledMetric(relativeTo: .caption2) private var markerSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 4) {
            Text("\(number)")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.black)
                .frame(width: markerSize, height: markerSize)
                .background(.orange, in: Circle())
            if showsAirtime {
                Text(BermsFormat.airtime(airtime))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, showsAirtime ? 5 : 0)
        .padding(.vertical, showsAirtime ? 3 : 0)
        .background {
            if showsAirtime {
                Capsule().fill(.regularMaterial)
            }
        }
        .overlay {
            if showsAirtime {
                Capsule().stroke(.orange, lineWidth: 1.5)
            }
        }
        .accessibilityLabel("Jump \(number), \(BermsFormat.airtime(airtime))")
    }
}
