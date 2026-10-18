import Foundation

let wheel = WheelCoalescer()
wheel.sensitivity = 3
var batches: [WheelCoalescer.Batch] = []
wheel.onBatch = { batches.append($0) }
wheel.add(direction: .left, deviceID: "a")
wheel.add(direction: .left, deviceID: "a")
wheel.flush()
wheel.add(direction: .right, deviceID: "a")
wheel.flush()
precondition(batches.isEmpty, "Opposite directions must never combine")
wheel.add(direction: .right, deviceID: "b")
wheel.add(direction: .right, deviceID: "b")
wheel.flush()
precondition(batches.isEmpty, "Different devices must never combine")
wheel.add(direction: .right, deviceID: "b")
wheel.flush()
precondition(batches == [.init(direction: .right, deviceID: "b", steps: 1)])
print("Wheel remainder ownership passed")
