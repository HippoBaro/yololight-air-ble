import SwiftUI

struct ControlPanel: View {
    @ObservedObject var model: LightsModel
    let layout: PanelLayout

    var body: some View {
        ScrollView {
            if model.lights.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No Lights Found", systemImage: "lightbulb.slash").font(.headline)
                    Text(model.status).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: PanelLayout.rowSpacing) {
                    ForEach(model.lights) { light in
                        LightControls(model: light, title: model.title(for: light))
                        if light.id != model.lights.last?.id {
                            Divider().frame(height: PanelLayout.separatorHeight)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: layout.viewportHeight, alignment: .top)
        .padding(PanelLayout.padding)
        .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
    }
}

private struct LightControls: View {
    @ObservedObject var model: LightModel
    let title: String
    private var presentation: LightPresentation { model.presentation }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                        .help("\(model.light.name)\n\(model.id.uuidString)")
                    Label(presentation.title,
                          systemImage: model.failureMessage == nil ? presentation.symbol : "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(model.isOn.map { $0 ? "On" : "Off" } ?? "Unknown")
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Toggle("Power", isOn: Binding(get: { model.isOn ?? false }, set: model.setPower))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .accessibilityIdentifier("power.\(model.id.uuidString)")
                        .accessibilityValue(model.powerAccessibilityValue)
                        .accessibilityHint(model.canControl
                            ? "Adjust to connect and set power. Unknown means the switch position has not been read from the light."
                            : "Wait for the current operation to finish.")
                        .allowsHitTesting(model.canControl)
                        .accessibilityRespondsToUserInteraction(model.canControl)
                }
                .frame(width: 86, height: 20, alignment: .trailing)
            }

            sliderRow(symbol: "sun.max", title: "Brightness", text: model.brightnessText,
                      accessibilityValue: model.brightnessAccessibilityValue,
                      value: Binding(get: { model.brightness }, set: model.setBrightness),
                      range: 0...100, step: 1)
            sliderRow(symbol: "thermometer.medium", title: "Color temperature", text: model.temperatureText,
                      accessibilityValue: model.temperatureAccessibilityValue,
                      value: Binding(get: { model.temperature }, set: model.setTemperature),
                      range: model.temperatureRange, step: 100)

            // Keep the footer's slot even when verified. Otherwise a hint or
            // error changes this row's height and moves the sliders below it.
            Group {
                if let failure = model.failureMessage {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure).lineLimit(1).help(failure)
                            .accessibilityLabel(failure)
                        Text("Adjust a control to retry.").lineLimit(1)
                    }
                } else if let hint = presentation.hint {
                    Text(hint).lineLimit(2)
                } else {
                    Color.clear.accessibilityHidden(true)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: PanelLayout.footerHeight, alignment: .topLeading)
        }
        .frame(height: PanelLayout.rowHeight, alignment: .top)
        .help(model.status)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(presentation.accessibilityContext)")
        .onDisappear { model.setEditing(false) }
    }

    private func sliderRow(symbol: String, title: String, text: String, accessibilityValue: String,
                           value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.callout).foregroundStyle(.secondary)
                .frame(width: 16).help(title).accessibilityHidden(true)
            Slider(value: value, in: range, step: step, onEditingChanged: model.setEditing) {
                Text(title)
            }
            .controlSize(.small)
            .labelsHidden()
            .accessibilityIdentifier("slider.\(model.id.uuidString).\(symbol)")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(model.canControl
                ? "Adjust to connect and apply a setting."
                : "Wait for the current operation to finish.")
            .allowsHitTesting(model.canControl)
            .accessibilityRespondsToUserInteraction(model.canControl)
            .frame(height: 20)
            Text(text).font(.callout).monospacedDigit().lineLimit(1)
                .foregroundStyle(.primary)
                .frame(width: 56, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 20)
    }
}
