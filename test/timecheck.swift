// 测试程序：分别通过多条路径读取当前时间，用来验证注入是否生效。
import Foundation

let fmt = DateFormatter()
fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

func show(_ label: String, _ secs: Double) {
    print(label.padding(toLength: 24, withPad: " ", startingAt: 0),
          fmt.string(from: Date(timeIntervalSince1970: secs)))
}

let rounds = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 1 : 1
for i in 0..<rounds {
    if i > 0 { Thread.sleep(forTimeInterval: 1); print("---") }
    show("time()", Double(time(nil)))
    var tv = timeval(); gettimeofday(&tv, nil)
    show("gettimeofday()", Double(tv.tv_sec))
    var ts = timespec(); clock_gettime(CLOCK_REALTIME, &ts)
    show("clock_gettime()", Double(ts.tv_sec))
    show("clock_gettime_nsec_np()", Double(clock_gettime_nsec_np(CLOCK_REALTIME)) / 1e9)
    show("Foundation Date()", Date().timeIntervalSince1970)
}
