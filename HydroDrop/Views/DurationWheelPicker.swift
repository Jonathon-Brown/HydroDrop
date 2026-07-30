import SwiftUI

/// A two-wheel hours/minutes duration picker, styled like the Clock app's Timer.
/// Clamps the resulting total to `range`, snapping the wheels back in bounds.
struct DurationWheelPicker: View {
    @Binding var totalMinutes: Int
    let range: ClosedRange<Int>

    private let minuteOptions = Array(stride(from: 0, through: 55, by: 5))

    private var hourOptions: [Int] {
        Array(0...(range.upperBound / 60))
    }

    private var hours: Int { totalMinutes / 60 }
    private var minutes: Int { totalMinutes % 60 }

    var body: some View {
        HStack(spacing: 0) {
            Picker("Hours", selection: hourBinding) {
                ForEach(hourOptions, id: \.self) { hour in
                    Text("\(hour) hr").tag(hour)
                }
            }
            .pickerStyle(.wheel)

            Picker("Minutes", selection: minuteBinding) {
                ForEach(minuteOptions, id: \.self) { minute in
                    Text("\(minute) min").tag(minute)
                }
            }
            .pickerStyle(.wheel)
        }
        // Five 32pt rows, so the selection sits centred between whole rows
        // instead of slicing the outermost ones through the text.
        .frame(height: 160)
    }

    private var hourBinding: Binding<Int> {
        Binding(
            get: { hours },
            set: { totalMinutes = clamp($0 * 60 + minutes) }
        )
    }

    private var minuteBinding: Binding<Int> {
        Binding(
            get: { minutes },
            set: { totalMinutes = clamp(hours * 60 + $0) }
        )
    }

    private func clamp(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

#Preview {
    @Previewable @State var minutes = 120
    DurationWheelPicker(totalMinutes: $minutes, range: 20...120)
}
