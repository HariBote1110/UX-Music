import Foundation

struct ProgressEmitter {
    func emit(stage: String, percent: Double) {
        let payload = ["stage": stage, "percent": percent] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
