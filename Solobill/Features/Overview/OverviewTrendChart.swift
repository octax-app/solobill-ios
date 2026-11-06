import Charts
import SwiftUI

/// Profit for each of the last 12 months. Bars plot the server's scaled integers directly.
/// Drag across the chart to read a month.
struct OverviewTrendChart: View {
    let points: [Overview.TrendPoint]
    let currency: String

    @State private var selected: String?

    private var shown: Overview.TrendPoint? {
        points.first { $0.month == selected } ?? points.last
    }

    /// Whole units, as on the web. A scaled value such as 1,250,000 reads "125".
    private func axisLabel(_ value: Int) -> String {
        String(Money.formatAmount(value, currency: currency).split(separator: ".")[0])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let shown {
                LabeledContent(shown.month) {
                    Text(Money.format(shown.profit, currency))
                        .monospacedDigit()
                }
                .font(.subheadline)
            }
            Chart(points) { point in
                BarMark(
                    x: .value("Month", point.month),
                    y: .value("Profit", point.profit),
                    width: .ratio(0.6)
                )
                .cornerRadius(3)
                .opacity(selected == nil || selected == point.month ? 1 : 0.4)
                .accessibilityLabel(point.month)
                .accessibilityValue(Money.format(point.profit, currency))
            }
            .chartXSelection(value: $selected)
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let month = value.as(String.self) {
                            Text(month.suffix(2))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Int.self) {
                            Text(axisLabel(amount))
                        }
                    }
                }
            }
            .frame(height: 200)
        }
        .padding(.vertical, 4)
    }
}
