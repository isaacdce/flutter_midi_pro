import Flutter
import UIKit
import AVFoundation

public class FlutterMidiProPlugin: NSObject, FlutterPlugin {
  private final class SoundFontState {
    let url: URL
    let engine: AVAudioEngine
    var samplersByChannel: [Int: AVAudioUnitSampler] = [:]

    init(url: URL) {
      self.url = url
      self.engine = AVAudioEngine()
    }
  }

  private let audioQueue = DispatchQueue(
    label: "com.oneonone.flutter_midi_pro.audio",
    qos: .userInitiated
  )

  private var soundfonts: [Int: SoundFontState] = [:]
  private var nextSoundfontId = 1

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "flutter_midi_pro",
      binaryMessenger: registrar.messenger()
    )

    let instance = FlutterMidiProPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "loadSoundfont":
      loadSoundfont(call, result: result)

    case "selectInstrument":
      selectInstrument(call, result: result)

    case "playNote":
      playNote(call, result: result)

    case "stopNote":
      stopNote(call, result: result)

    case "stopAllNotes":
      stopAllNotes(call, result: result)

    case "controlChange":
      controlChange(call, result: result)

    case "unloadSoundfont":
      unloadSoundfont(call, result: result)

    case "dispose":
      dispose(result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Public method handlers

  private func loadSoundfont(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let path = args["path"] as? String,
      let bank = args["bank"] as? Int,
      let program = args["program"] as? Int
    else {
      result(badArgs("Invalid loadSoundfont args"))
      return
    }

    audioQueue.async {
      do {
        let url = URL(fileURLWithPath: path)
        let state = SoundFontState(url: url)

        // Compatibility behavior: prepare channel 0 only.
        // The original plugin eagerly prepared all 16 channels; this fork does not.
        let sampler = try self.sampler(for: state, channel: 0)
        try self.loadInstrument(
          sampler: sampler,
          url: url,
          bank: bank,
          program: program,
          channel: 0
        )

        let sfId = self.nextSoundfontId
        self.nextSoundfontId += 1
        self.soundfonts[sfId] = state

        DispatchQueue.main.async {
          result(sfId)
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "SOUND_FONT_LOAD_FAILED",
            message: "Failed to load soundfont",
            details: [
              "path": path,
              "fileExists": FileManager.default.fileExists(atPath: path),
              "error": error.localizedDescription
            ]
          ))
        }
      }
    }
  }

  private func selectInstrument(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let sfId = args["sfId"] as? Int,
      let channel = args["channel"] as? Int,
      let bank = args["bank"] as? Int,
      let program = args["program"] as? Int
    else {
      result(badArgs("Invalid selectInstrument args"))
      return
    }

    audioQueue.async {
      do {
        guard let state = self.soundfonts[sfId] else {
          throw PluginError.soundfontNotFound(sfId)
        }

        let sampler = try self.sampler(for: state, channel: channel)
        try self.loadInstrument(
          sampler: sampler,
          url: state.url,
          bank: bank,
          program: program,
          channel: channel
        )

        DispatchQueue.main.async {
          result(nil)
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "SELECT_INSTRUMENT_FAILED",
            message: "Failed to select instrument",
            details: [
              "sfId": sfId,
              "channel": channel,
              "bank": bank,
              "program": program,
              "error": error.localizedDescription
            ]
          ))
        }
      }
    }
  }

  private func playNote(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let sfId = args["sfId"] as? Int,
      let channel = args["channel"] as? Int,
      let key = args["key"] as? Int,
      let velocity = args["velocity"] as? Int
    else {
      result(badArgs("Invalid playNote args"))
      return
    }

    audioQueue.async {
      guard let sampler = self.soundfonts[sfId]?.samplersByChannel[channel] else {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "CHANNEL_NOT_LOADED",
            message: "No sampler loaded for channel",
            details: ["sfId": sfId, "channel": channel]
          ))
        }
        return
      }

      sampler.startNote(
        UInt8(clamping: key),
        withVelocity: UInt8(clamping: velocity),
        onChannel: UInt8(clamping: channel)
      )

      DispatchQueue.main.async {
        result(nil)
      }
    }
  }

  private func stopNote(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let sfId = args["sfId"] as? Int,
      let channel = args["channel"] as? Int,
      let key = args["key"] as? Int
    else {
      result(badArgs("Invalid stopNote args"))
      return
    }

    audioQueue.async {
      let sampler = self.soundfonts[sfId]?.samplersByChannel[channel]

      sampler?.stopNote(
        UInt8(clamping: key),
        onChannel: UInt8(clamping: channel)
      )

      DispatchQueue.main.async {
        result(nil)
      }
    }
  }

  private func stopAllNotes(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let sfId = args["sfId"] as? Int
    else {
      result(badArgs("Invalid stopAllNotes args"))
      return
    }

    audioQueue.async {
      guard let state = self.soundfonts[sfId] else {
        DispatchQueue.main.async {
          result(nil)
        }
        return
      }

      for (channel, sampler) in state.samplersByChannel {
        let midiChannel = UInt8(clamping: channel)

        // 64 = sustain off, 120 = all sound off, 123 = all notes off.
        sampler.sendController(64, withValue: 0, onChannel: midiChannel)
        sampler.sendController(120, withValue: 0, onChannel: midiChannel)
        sampler.sendController(123, withValue: 0, onChannel: midiChannel)
      }

      DispatchQueue.main.async {
        result(nil)
      }
    }
  }

  private func controlChange(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let sfId = args["sfId"] as? Int,
      let channel = args["channel"] as? Int,
      let controller = args["controller"] as? Int,
      let value = args["value"] as? Int
    else {
      result(badArgs("Invalid controlChange args"))
      return
    }

    audioQueue.async {
      guard let sampler = self.soundfonts[sfId]?.samplersByChannel[channel] else {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "CHANNEL_NOT_LOADED",
            message: "No sampler loaded for channel",
            details: ["sfId": sfId, "channel": channel]
          ))
        }
        return
      }

      sampler.sendController(
        UInt8(clamping: controller),
        withValue: UInt8(clamping: value),
        onChannel: UInt8(clamping: channel)
      )

      DispatchQueue.main.async {
        result(nil)
      }
    }
  }

  private func unloadSoundfont(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let sfId = args["sfId"] as? Int
    else {
      result(badArgs("Invalid unloadSoundfont args"))
      return
    }

    audioQueue.async {
      if let state = self.soundfonts[sfId] {
        for (channel, sampler) in state.samplersByChannel {
          let midiChannel = UInt8(clamping: channel)
          sampler.sendController(64, withValue: 0, onChannel: midiChannel)
          sampler.sendController(120, withValue: 0, onChannel: midiChannel)
          sampler.sendController(123, withValue: 0, onChannel: midiChannel)
        }

        state.engine.stop()
        self.soundfonts.removeValue(forKey: sfId)
      }

      DispatchQueue.main.async {
        result(nil)
      }
    }
  }

  private func dispose(result: @escaping FlutterResult) {
    audioQueue.async {
      for (_, state) in self.soundfonts {
        state.engine.stop()
      }

      self.soundfonts.removeAll()

      DispatchQueue.main.async {
        result(nil)
      }
    }
  }

  // MARK: - Audio helpers

  private func sampler(
    for state: SoundFontState,
    channel: Int
  ) throws -> AVAudioUnitSampler {
    if let existing = state.samplersByChannel[channel] {
      return existing
    }

    let sampler = AVAudioUnitSampler()

    state.engine.attach(sampler)
    state.engine.connect(
      sampler,
      to: state.engine.mainMixerNode,
      format: nil
    )

    state.samplersByChannel[channel] = sampler

    if !state.engine.isRunning {
      try state.engine.start()
    }

    return sampler
  }

  private func loadInstrument(
    sampler: AVAudioUnitSampler,
    url: URL,
    bank: Int,
    program: Int,
    channel: Int
  ) throws {
    let bankValues = resolvedBankValues(bank: bank)

    try sampler.loadSoundBankInstrument(
      at: url,
      program: UInt8(clamping: program),
      bankMSB: bankValues.msb,
      bankLSB: bankValues.lsb
    )

    sampler.sendProgramChange(
      UInt8(clamping: program),
      bankMSB: bankValues.msb,
      bankLSB: bankValues.lsb,
      onChannel: UInt8(clamping: channel)
    )
  }

  private func resolvedBankValues(bank: Int) -> (msb: UInt8, lsb: UInt8) {
    if bank == 128 {
      return (
        UInt8(kAUSampler_DefaultPercussionBankMSB),
        0
      )
    }

    return (
      UInt8(kAUSampler_DefaultMelodicBankMSB),
      UInt8(clamping: bank)
    )
  }

  // MARK: - Errors

  private func badArgs(_ message: String) -> FlutterError {
    FlutterError(
      code: "BAD_ARGS",
      message: message,
      details: nil
    )
  }

  private enum PluginError: LocalizedError {
    case soundfontNotFound(Int)

    var errorDescription: String? {
      switch self {
      case .soundfontNotFound(let sfId):
        return "Soundfont not found: \(sfId)"
      }
    }
  }
}