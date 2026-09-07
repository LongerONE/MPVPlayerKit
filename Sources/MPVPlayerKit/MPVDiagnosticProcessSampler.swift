import Darwin
import Foundation

/// 进程级指标，不是播放器独占 CPU；100% 表示占满一个逻辑核心，可超过 100%。
struct MPVDiagnosticProcessSampler {
    private var previousCPU: Double?
    private var previousUptime: Double?

    mutating func sample() -> [String: String] {
        var result = ["进程CPU百分比": "不可用", "进程物理内存字节": "不可用"]
        var usage = rusage()
        let uptime = ProcessInfo.processInfo.systemUptime
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            if let previousCPU, let previousUptime,
               uptime > previousUptime, cpu >= previousCPU {
                result["进程CPU百分比"] = String(format: "%.2f", (cpu - previousCPU) / (uptime - previousUptime) * 100)
                result["CPU采样间隔秒"] = String(format: "%.3f", uptime - previousUptime)
            }
            previousCPU = cpu
            previousUptime = uptime
        } else {
            previousCPU = nil
            previousUptime = nil
        }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if status == KERN_SUCCESS { result["进程物理内存字节"] = String(info.phys_footprint) }
        return result
    }
}

/// mpv 队列独占；计数器回退（例如换解码器或重新加载）时不产生负增量。
struct MPVDiagnosticCounter {
    private var previous: Int64?

    mutating func update(_ current: Int64?) -> String {
        defer { previous = current }
        guard let current, let previous, current >= previous else { return "不可用" }
        return String(current - previous)
    }
}
