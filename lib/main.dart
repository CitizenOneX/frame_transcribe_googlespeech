import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/audio_data_response.dart';
import 'package:simple_frame_app/tx/code.dart';
import 'package:simple_frame_app/tx/plain_text.dart';
import 'package:vosk_flutter/vosk_flutter.dart';
import 'package:simple_frame_app/text_utils.dart';
import 'package:simple_frame_app/simple_frame_app.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

/// SimpleFrameAppState mixin helps to manage the lifecycle of the Frame connection outside of this file
class MainAppState extends State<MainApp> with SimpleFrameAppState {

  MainAppState() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }

  /// speech to text application members
  static const _modelName = 'vosk-model-small-en-us-0.15.zip';
  final _vosk = VoskFlutterPlugin.instance();
  late final Model _model;
  late final Recognizer _recognizer;
  static const _sampleRate = 8000; // Note: Vosk Android models require 16kHz sample rate

  String _partialResult = "N/A";
  String _finalResult = "N/A";
  static const _textStyle = TextStyle(fontSize: 30);

  @override
  void initState() {
    super.initState();
    currentState = ApplicationState.initializing;
    // asynchronously kick off Vosk initialization
    _initVosk();
  }

  @override
  void dispose() async {
    _model.dispose();
    _recognizer.dispose();
    super.dispose();
  }

  void _initVosk() async {
    final enSmallModelPath = await ModelLoader().loadFromAssets('assets/$_modelName');
    _model = await _vosk.createModel(enSmallModelPath);
    _recognizer = await _vosk.createRecognizer(model: _model, sampleRate: _sampleRate);

    currentState = ApplicationState.disconnected;
    if (mounted) setState(() {});
  }

  /// This application uses vosk speech-to-text to listen to audio from the Frame mic, convert to text,
  /// and send the text to the Frame in real-time. It has a running main loop in this function
  /// and also on the Frame (frame_app.lua)
  @override
  Future<void> run() async {
    currentState = ApplicationState.running;
    _partialResult = '';
    _finalResult = '';
    if (mounted) setState(() {});

    // tell Frame to start streaming audio
    await frame!.sendMessage(TxCode(msgCode: 0x30));

    try {
      var audioSampleStream = audioDataStreamResponse(frame!.dataResponse);

      String prevText = '';

      // loop over the incoming audio data and send reults to Frame
      await for (var audioSample in audioSampleStream!) {
        // if the user has clicked Stop we want to jump out of the main loop and stop processing
        if (currentState != ApplicationState.running) {
          break;
        }

        // recognizer blocks until it has something
        final resultReady = await _recognizer.acceptWaveformBytes(Uint8List.fromList(audioSample));

        // TODO consider enabling alternatives, and word times, and ...?
        String text = resultReady ?
            jsonDecode(await _recognizer.getResult())['text']
          : jsonDecode(await _recognizer.getPartialResult())['partial'];

        // If the text is the same as the previous one, we don't send it to Frame and force a redraw
        // The recognizer often produces a bunch of empty string in a row too, so this means
        // we send the first one (clears the display) but not subsequent ones
        // Often the final result matches the last partial, so if it's a final result then show it
        // on the phone but don't send it
        if (text == prevText) {
          if (resultReady) {
            setState(() { _finalResult = text; _partialResult = ''; });
          }
          continue;
        }
        else if (text.isEmpty) {
          // turn the empty string into a single space and send
          // still can't put it through the wrapped-text-chunked-sender
          // because it will be zero bytes payload so no message will
          // be sent.
          // Users might say this first empty partial
          // comes a bit soon and hence the display is cleared a little sooner
          // than they want (not like audio hangs around in the air though
          // after words are spoken!)
          await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: ' '));
          prevText = '';
          continue;
        }

        if (_log.isLoggable(Level.FINE)) {
          _log.fine('Recognized text: $text');
        }

        // send current text to Frame
        String wrappedText = TextUtils.wrapText(text, 640, 4);
        await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: wrappedText));

        // update the phone UI too
        setState(() => resultReady ? _finalResult = text : _partialResult = text);
        prevText = text;
      }

      // tell Frame to stop streaming audio
      await frame!.sendMessage(TxCode(msgCode: 0x31));

    } catch (e) {
      _log.fine('Error executing application logic: $e');
    }

    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  /// The run() function will keep running until we interrupt it here
  /// and it will stop listening to audio
  @override
  Future<void> cancel() async {
    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Speech-to-Text',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text("Frame Speech-to-Text"),
          actions: [getBatteryWidget()]
        ),
        body: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Align(alignment: Alignment.centerLeft,
                  child: Text('Partial: $_partialResult', style: _textStyle)
                ),
                const Divider(),
                Align(alignment: Alignment.centerLeft,
                  child: Text('Final: $_finalResult', style: _textStyle)
                ),
              ],
            ),
          ),
        ),
        floatingActionButton: getFloatingActionButtonWidget(const Icon(Icons.mic), const Icon(Icons.mic_off)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }
}
