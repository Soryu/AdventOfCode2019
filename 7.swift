#!/usr/bin/env swift

// After failing to make this work (in reasonable time) asynchronously with blocking I/O
// here is an over-engineered but nicely working synchronous variant of the intcode computer :)
// Includes the input program in the source code.

// https://adventofcode.com/2019/day/7

typealias PID = Int
typealias Port = Int
typealias StreamData = [Int]

protocol OSProtocol {
  func read(process: Process) throws -> Int
  func write(process: Process, value: Int)
}

enum OSError: Error {
  case blocked(Port)
}

protocol Process {
  var pid: PID { get }
  func step() -> ProcessStepResult
}

struct ProcessInfo {
  let pid: PID
  let process: Process
  var status: ProcessStatus = .initial

  var inputPort: Port?
  var outputPort: Port?
  
  init(pid: PID, process: Process) {
    self.pid = pid
    self.process = process
  }
}

enum ProcessStatus {
  case initial
  case running
  case blocked(Port)
  case dead
}

enum ProcessStepResult {
  case running
  case blocked(Port)
  case finished
  case error
}

struct Stream {
  let port: Port
  var data: StreamData
}

class OS {
  private var processes = [Int:ProcessInfo]()
  private var streams = [Port:Stream]()
  private var _nextPID: PID = 1
  private var _nextPort: Port = 1
  private var debug = false
  
  func spawnIntProcess(memory: [Int]) -> IntProcess {
    let pid = _nextPID
    _nextPID += 1

    if debug { print("[os] spawning process \(pid)") }
    
    let process = IntProcess(system: self, memory: memory, pid: pid)
    processes[pid] = ProcessInfo(pid: pid, process: process)
    
    return process
  }
  
  func createStream(initialData: StreamData = []) -> Port {
    let port = _nextPort
    _nextPort += 1
    
    streams[port] = Stream(port: port, data: initialData)
    return port
  }
  
  func readStream(port: Port) -> Stream {
    return streams[port]!
  }
  
  func updatePorts(for process: Process, input: Port, output: Port) {
    processes[process.pid]!.inputPort = input
    processes[process.pid]!.outputPort = output
  }
  
  func runSynchronously() {
    for (pid, info) in processes {
      guard case .initial = info.status else { fatalError() }
      processes[pid]!.status = .running
    }

    while true {
      let check = stats()
      if check.running == 0 && check.blocked == 0 {
        if debug { print("[os] finished") }
        break
      }
      
      if check.running == 0 && check.blocked > 0 {
        print("[os] DEADLOCK")
        break
      }
      
      for (pid, info) in processes {
        if case .running = info.status {
          let result = info.process.step()
          switch result {
          case .error, .finished:
            processes[pid]!.status = .dead
          case .running:
            break
          case .blocked(let port):
            processes[pid]!.status = .blocked(port)
          }
        }
      }
    }
    
    if debug { print("[os] no more active processes") }
  }
  
  private func stats() -> (running: Int, blocked: Int, dead: Int) {
    var running = 0
    var blocked = 0
    var dead = 0
    for (_, info) in processes {
      if case .running = info.status { running += 1 }
      if case .dead = info.status { dead += 1 }
      if case .blocked(_) = info.status { blocked += 1 }
    }
    
    return (running, blocked, dead)
  }
  
}

extension OS: OSProtocol {
  func read(process: Process) throws -> Int {
    let info = processes[process.pid]!
    guard let port = info.inputPort else {
      fatalError("process \(process.pid) tries to read from undefined input port")
    }
    
    guard var stream = streams[port] else {
      fatalError("no stream on port \(port)")
    }
    
    if !stream.data.isEmpty {
      let value = stream.data.remove(at: 0)
      streams[port] = stream
      
      return value
    }
    
    if debug { print("[os] WAIT \(process.pid)") }
    processes[process.pid]!.status = .blocked(port)
    
    throw OSError.blocked(port)
  }
  
  func write(process: Process, value: Int) {
    let info = processes[process.pid]!
    guard let port = info.outputPort else {
      fatalError("process \(process.pid) tries to read from undefined input port")
    }
    
    guard streams[port] != nil else {
      fatalError("no stream on port \(port)")
    }
    
    streams[port]!.data.append(value)
    
    for (pid, info) in processes {
      if case .blocked(let candidatePort) = info.status, candidatePort == port {
        processes[pid]!.status = .running // unblock this port
      }
    }
  }

}

class IntProcess : Process {
  
  let system: OSProtocol
  let pid: PID
  let debug = false

  // internal state, written by side effects of step() function
  var memory: [Int]
  var ip: Int = 0
  
  init(system: OSProtocol, memory: [Int], pid: PID) {
    self.system = system
    self.memory = memory
    self.pid = pid
  }
  
  func step() -> ProcessStepResult {
    assert(ip >= 0)
    assert(ip < memory.count)
    
    let command = memory[ip]
    
    let opcode = command % 100
    let p1_mode = command % 1000 / 100
    let p2_mode = command % 10000 / 1000
    
    var length = 0
    switch opcode {
    case 1:
      if debug { print("[\(pid) \(ip) \(command)] adding") }
      length = 4
      let p1 = IntProcess.p(1, memory, ip, p1_mode == 1)
      let p2 = IntProcess.p(2, memory, ip, p2_mode == 1)
      let result_pointer = memory[ip+3]
      memory[result_pointer] = p1 + p2
      
    case 2:
      if debug { print("[\(pid) \(ip)] multiplying") }
      length = 4
      let p1 = IntProcess.p(1, memory, ip, p1_mode == 1)
      let p2 = IntProcess.p(2, memory, ip, p2_mode == 1)
      let result_pointer = memory[ip+3]
      memory[result_pointer] = p1 * p2
      
    case 3:
      if debug { print("[\(pid) \(ip)] reading input") }
      length = 2
      let result_pointer = memory[ip+1]
      do {
        memory[result_pointer] = try system.read(process: self)
      } catch OSError.blocked(let blockedPort) {
        return .blocked(blockedPort)
      } catch {
        print("Caught unknown exception")
        return .error
      }
      
    case 4:
      if debug { print("[\(pid) \(ip)] writing output") }
      length = 2
      let p1 = IntProcess.p(1, memory, ip, p1_mode == 1)
      system.write(process:self, value: p1)
      
    case 5:
      if debug { print("[\(pid) \(ip)] jump if true") }
      length = 3
      let p1 = IntProcess.p(1, memory, ip, p1_mode == 1)
      let p2 = IntProcess.p(2, memory, ip, p2_mode == 1)
      if p1 != 0 {
        // set instruction pointer to p2
        length = p2 - ip
      }
      
    case 6:
      if debug { print("[\(pid) \(ip)] jump if false") }
      length = 3
      let p1 = IntProcess.p(1, memory, ip, p1_mode == 1)
      let p2 = IntProcess.p(2, memory, ip, p2_mode == 1)
      if p1 == 0 {
        // set instruction pointer to p2
        length = p2 - ip
      }
      
    case 7:
      if debug { print("[\(pid) \(ip)] less than") }
      length = 4
      let p1 = IntProcess.p(1, memory, ip, p1_mode == 1)
      let p2 = IntProcess.p(2, memory, ip, p2_mode == 1)
      let result_pointer = memory[ip+3]
      memory[result_pointer] = p1 < p2 ? 1 : 0
      
    case 8:
      if debug { print("[\(pid) \(ip)] equals") }
      length = 4
      let p1 = IntProcess.p(1, memory, ip, p1_mode == 1)
      let p2 = IntProcess.p(2, memory, ip, p2_mode == 1)
      let result_pointer = memory[ip+3]
      memory[result_pointer] = p1 == p2 ? 1 : 0
      
    case 99:
      if debug { print("[\(pid) \(ip)] END PROGRAM") }
      return .finished
      
    default:
      print("[\(pid) \(ip)] ERROR Unknown opcode \(opcode)")
      return .error
    }
    
    ip += length
    return .running
  }
  
  static func p(_ pos: Int, _ memory: [Int], _ ip: Int, _ isImmediate: Bool) -> Int {
    var value = memory[ip + pos]
    if !isImmediate {
      value = memory[value]
    }
    return value
  }
  
}


func parseAsIntegers(_ input: String, _ separator: Character) -> [Int] {
  return input.split(separator: separator).map { Int(String($0))! }
}


let INPUT = """
3,8,1001,8,10,8,105,1,0,0,21,46,67,76,97,118,199,280,361,442,99999,3,9,1002,9,3,9,101,4,9,9,102,3,9,9,1001,9,3,9,1002,9,2,9,4,9,99,3,9,102,2,9,9,101,5,9,9,1002,9,2,9,101,2,9,9,4,9,99,3,9,101,4,9,9,4,9,99,3,9,1001,9,4,9,102,2,9,9,1001,9,4,9,1002,9,5,9,4,9,99,3,9,102,3,9,9,1001,9,2,9,1002,9,3,9,1001,9,3,9,4,9,99,3,9,101,1,9,9,4,9,3,9,1001,9,2,9,4,9,3,9,1001,9,1,9,4,9,3,9,1001,9,1,9,4,9,3,9,101,2,9,9,4,9,3,9,102,2,9,9,4,9,3,9,1002,9,2,9,4,9,3,9,1002,9,2,9,4,9,3,9,1001,9,2,9,4,9,3,9,101,1,9,9,4,9,99,3,9,102,2,9,9,4,9,3,9,101,2,9,9,4,9,3,9,102,2,9,9,4,9,3,9,1002,9,2,9,4,9,3,9,102,2,9,9,4,9,3,9,1001,9,2,9,4,9,3,9,1001,9,1,9,4,9,3,9,102,2,9,9,4,9,3,9,101,1,9,9,4,9,3,9,101,2,9,9,4,9,99,3,9,1002,9,2,9,4,9,3,9,1001,9,1,9,4,9,3,9,101,2,9,9,4,9,3,9,1002,9,2,9,4,9,3,9,102,2,9,9,4,9,3,9,1001,9,1,9,4,9,3,9,1002,9,2,9,4,9,3,9,101,1,9,9,4,9,3,9,1002,9,2,9,4,9,3,9,1001,9,1,9,4,9,99,3,9,1001,9,2,9,4,9,3,9,1002,9,2,9,4,9,3,9,1002,9,2,9,4,9,3,9,101,2,9,9,4,9,3,9,1001,9,1,9,4,9,3,9,101,1,9,9,4,9,3,9,1001,9,2,9,4,9,3,9,1001,9,1,9,4,9,3,9,1002,9,2,9,4,9,3,9,1001,9,1,9,4,9,99,3,9,1002,9,2,9,4,9,3,9,101,2,9,9,4,9,3,9,1002,9,2,9,4,9,3,9,101,2,9,9,4,9,3,9,1001,9,2,9,4,9,3,9,101,1,9,9,4,9,3,9,102,2,9,9,4,9,3,9,102,2,9,9,4,9,3,9,1001,9,2,9,4,9,3,9,1002,9,2,9,4,9,99
"""


func run(program: [Int], p1: Int, p2: Int, p3: Int, p4: Int, p5: Int) -> Stream {
  let os = OS()

  let process1 = os.spawnIntProcess(memory: program)
  let port1 = os.createStream(initialData: [p1, 0])
  
  let process2 = os.spawnIntProcess(memory: program)
  let port2 = os.createStream(initialData: [p2])
  
  let process3 = os.spawnIntProcess(memory: program)
  let port3 = os.createStream(initialData: [p3])
  
  let process4 = os.spawnIntProcess(memory: program)
  let port4 = os.createStream(initialData: [p4])
  
  let process5 = os.spawnIntProcess(memory: program)
  let port5 = os.createStream(initialData: [p5])
  
  os.updatePorts(for: process1, input: port1, output: port2)
  os.updatePorts(for: process2, input: port2, output: port3)
  os.updatePorts(for: process3, input: port3, output: port4)
  os.updatePorts(for: process4, input: port4, output: port5)
  os.updatePorts(for: process5, input: port5, output: port1)
  
  os.runSynchronously()
  return os.readStream(port: port1)
}


func runWrapper(phase_range: ClosedRange<Int>) -> Int {
  let program = parseAsIntegers(INPUT, ",")

  var max_output = 0
  for p1 in phase_range {
    for p2 in phase_range {
      if p2 == p1 { continue } // each phase setting is used exactly once!
      for p3 in phase_range {
        if p3 == p2 || p3 == p1 { continue }
        for p4 in phase_range {
          if p4 == p3 || p4 == p2 || p4 == p1 { continue }
          for p5 in phase_range {
            if p5 == p4 || p5 == p3 || p5 == p2 || p5 == p1 { continue }

            let stream = run(program: program, p1: p1, p2: p2, p3: p3, p4: p4, p5: p5)
            max_output = max(max_output, stream.data.last!)
          }
        }
      }
    }
  }
  return max_output
}

let a = runWrapper(phase_range: (0...4))
print("7A \(a)")

let b = runWrapper(phase_range: (5...9))
print("7B \(b)")
