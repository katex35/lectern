# Lectern

Lectern records your lectures on a Mac and turns them into study notes. It writes the transcript, the notes and practice questions with an AI account you connect yourself, and keeps everything in plain files on your disk.

## What it does

- **Records** in a separate helper process, so a lecture keeps recording if the app quits. Breaks split a lecture into parts that play back as one timeline.
- **Transcribes** with Gemini's transcription model. The audio is cut at quiet moments into five-minute pieces; an interrupted run continues where it stopped.
- **Writes notes and questions** in your language from the transcript, with formulas, tables and the notes you typed during the lecture.
- **Places board photos** at the moment they were taken (from the camera's own time) and puts them in the section of the notes that was being explained.
- **Answers questions** about a lecture from its notes and transcript.
- **Knows your timetable**: weekly lecture times, term dates, exams and deadlines, with a reminder before each lecture that can start the recording.
- **Searches** every lecture's notes, transcript and conversation; a transcript hit plays the recording from that moment.
- **Draws covers** for courses and lectures from their topic. The picture idea is checked first, and the image model is told to leave out people, text and symbols.
- Turkish and English.

## Accounts

Lectern has no server. It talks only to the services you connect, with your own keys, which are kept in the macOS Keychain.

| Task | Works with |
|---|---|
| Transcription | A Google AI Studio key (Gemini) |
| Notes, questions, answers | Sign in with ChatGPT (answers count against your plan), a Claude, OpenAI or Gemini key, or any server that speaks the OpenAI Chat Completions format, such as a local one |
| Covers | An OpenAI or Gemini key (the ChatGPT sign-in cannot make images) |

## Your files

Everything lives in `~/Documents/Lectern`:

```
Courses/<course>/course.json          name, language, weekly times, exams
Courses/<course>/<date> Week <n>/     one lecture: recordings, session.json,
                                      transcript.txt, notes.md, questions.md,
                                      chat.json, board/ photos, cover.jpg
Meetings/<date> <time>/               the same for a meeting
Covers/<course>.jpg                   course covers
```

Notes are Markdown; when Lectern writes a file again, the old one goes to `.lectern/previous` in the lecture's folder.

## Building

Lectern needs macOS 14 or later and Swift 5.10 or later (Xcode 16).

```sh
swift build
swift test
scripts/bundle.sh          # builds build/Lectern.app, signed for this Mac
open build/Lectern.app
```

The microphone permission and notifications need the app bundle; `swift run Lectern` works for everything else.

### For development

| Variable | Effect |
|---|---|
| `LECTERN_LIBRARY=<folder>` | Use another library folder |
| `LECTERN_SIMULATE=<seconds>` | Record a generated tone instead of the microphone |
| `LECTERN_FAKE_AI=1` | Run transcription, notes, chat and covers on stand-ins, without any account |
| `LECTERN_SNAPSHOT=<folder>` | Save each main screen as a PNG and quit |
| `LECTERN_IMPORT=<folder>` | Import lectures from the ders-kayit tool into an empty library |

## License

MIT, see [LICENSE](LICENSE).

## Türkçe

Lectern, Mac'te dersini kaydeder; kaydı yazıya döker, ders notunu ve çalışma sorularını senin bağladığın hesapla yazar. Her şey kendi diskinde, düz dosyalar halinde durur. Yazıya dökmek için Gemini anahtarı gerekir. Notlar için ChatGPT ile giriş, Claude, OpenAI ya da Gemini anahtarı veya yerel bir sunucu kullanılabilir. Anahtarlar macOS Anahtar Zinciri'nde saklanır. Lectern'in kendi sunucusu yoktur.
