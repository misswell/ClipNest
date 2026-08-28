import Foundation

enum CaptureState: String, Equatable {
    case idle
    case detecting
    case analyzing
    case generating
    case classifying
    case saving
    case completed
    case failed

    var title: String {
        switch self {
        case .idle: return "等待剪贴板"
        case .detecting: return "检测剪贴板"
        case .analyzing: return "分析内容"
        case .generating: return "生成笔记"
        case .classifying: return "选择分类"
        case .saving: return "保存笔记"
        case .completed: return "处理完成"
        case .failed: return "整理失败"
        }
    }

    var isProcessing: Bool {
        switch self {
        case .detecting, .analyzing, .generating, .classifying, .saving:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }
}
