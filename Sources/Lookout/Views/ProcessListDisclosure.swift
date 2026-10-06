import LookoutCore
import SwiftUI

struct ProcessListDisclosure: View {
    let metric: Metric
    let reading: MetricReading?
    let visible: Bool
    @ObservedObject var details: ProcessDetailsStore
    var initiallyExpanded = false
    @State private var expanded = false
    @State private var owner = UUID()
    private var list: ProcessListReading? {
        if metric == .power {
            guard case .power(let energy) = reading?.value else { return ProcessListReading(message: reading?.message ?? "측정을 시작하는 중") }
            return ProcessListReading(processes: energy.processes.map {
                ProcessUsage(id: $0.id, name: $0.name, primary: $0.watts)
            }, message: energy.message)
        }
        return details.readings[metric]
    }
    private var scope: String {
        switch metric {
        case .cpu: "CPU 사용률순 · 코어 1개 = 100%"
        case .memory: "메모리 점유량순"
        case .ssd: "저장공간은 프로세스 목록을 제공하지 않습니다."
        case .disk: "읽기 + 쓰기 속도순 · 전체 디스크"
        case .network: "다운로드 + 업로드 속도순 · 전체 인터페이스"
        case .gpu: "GPU 실행 시간 비율순 · 드라이버 추정치"
        case .power: "추정 전력순"
        }
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 7) {
                Text(scope).font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let list {
                    if let message = list.message {
                        Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if list.processes.isEmpty {
                        Text("현재 측정 구간의 사용 없음").foregroundStyle(.secondary)
                    } else {
                        if expanded && visible {
                            ForEach(list.processes) { process in
                                HStack(spacing: 8) {
                                    HStack(spacing: 5) {
                                        ProcessIcon(id: process.id)
                                        Text(process.name).lineLimit(1).truncationMode(.middle)
                                    }
                                    .help("\(process.name) · PID \(process.id.pid)")
                                    Spacer(minLength: 0)
                                    Text(value(process)).monospacedDigit().fixedSize()
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(process.name), PID \(process.id.pid)")
                                .accessibilityValue(value(process))
                            }
                        }
                        Text("접근 가능한 프로세스 중 상위 \(list.processes.count)개")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("프로세스 측정을 시작하는 중").foregroundStyle(.secondary)
                }
            }.font(.system(size: 10)).padding(.top, 5)
        } label: {
            Text("프로세스 · 최대 5개").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("processes-\(metric.rawValue)")
        .onAppear {
            expanded = initiallyExpanded
            updateDemand()
        }
        .onChange(of: expanded) { _, _ in updateDemand() }
        .onChange(of: visible) { _, value in
            if value { updateDemand() } else { close() }
        }
        .onDisappear { close() }
    }
    private func updateDemand() {
        details.setExpanded(expanded && visible, metric: metric, owner: owner)
    }
    private func close() {
        details.setExpanded(false, metric: metric, owner: owner)
        expanded = false
    }
    private func value(_ process: ProcessUsage) -> String {
        switch metric {
        case .cpu, .gpu: String(format: "%.1f%%", process.primary)
        case .memory: ValueFormat.memory(process.primary)
        case .ssd: "—"
        case .disk: "R \(ValueFormat.rate(process.primary))  W \(ValueFormat.rate(process.secondary ?? 0))"
        case .network: "↓ \(ValueFormat.rate(process.primary))  ↑ \(ValueFormat.rate(process.secondary ?? 0))"
        case .power: ValueFormat.watts(process.primary)
        }
    }
}
