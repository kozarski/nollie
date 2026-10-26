import Foundation
import UniformTypeIdentifiers

extension ChatSession {
    /// Supplied by the app. Converts an image the gateway cannot accept (a HEIC from Photos, for one)
    /// into a usable one and hands back the new bytes and name. Returning nil keeps the original.
    public typealias ImageTranscoder = @Sendable (Data, String) -> (Data, String)?
    nonisolated(unsafe) public static var imageTranscoder: ImageTranscoder?

    // MARK: Sending

    /// Sends what the person wrote, with any staged attachments. A busy bot gets it queued. Returns
    /// text for the composer to prefill when a slash command asks for that, or a sentence to show
    /// when the chat could not be opened.
    ///
    /// The message is fixed before anything waits: its words and the files staged at this moment
    /// belong to it alone. A second send while the first is still uploading cannot take them, and
    /// files the person stages afterwards are left for the next message.
    @discardableResult
    public func send(_ rawText: String) async -> String? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = staged
        if text.isEmpty && files.isEmpty { return nil }
        staged = []
        await awaitResume()
        if let failure = resumeError {
            staged = files + staged
            return "This chat could not be opened on the gateway: " + failure
        }
        composerHistory += text.isEmpty ? [] : [text]

        if text.hasPrefix("/") && files.isEmpty {
            return await dispatchSlash(text)
        } else if isRunning || isSubmitting {
            queue.append(QueuedMessage(text: text, attachments: files))
        } else {
            await submit(text: text, attachments: files, queued: false)
        }
        return nil
    }

    /// Uploads a message's files and hands it to the gateway. One message at a time: `isSubmitting`
    /// is set before the first wait, so a send during the upload queues behind this one. A file the
    /// gateway refused goes back to the staged strip to try again.
    func submit(text: String, attachments: [AttachmentPreview] = [], queued: Bool) async {
        isSubmitting = true
        interruptCause = nil
        var outgoing = text
        var sent: [AttachmentPreview] = []
        var refused: [AttachmentPreview] = []
        for file in attachments {
            do {
                if let reference = try await upload(file) {
                    outgoing += (outgoing.isEmpty ? "" : "\n") + reference
                }
                sent.append(file)
            } catch {
                refused.append(file)
                addFailure(Self.attachmentFailure(name: file.name, kind: file.kind, error: error))
            }
        }
        staged = refused + staged
        if text.isEmpty && sent.isEmpty {
            // Every file was refused and there are no words: nothing to send.
            isSubmitting = false
            drainQueue()
            return
        }
        addRow(.user(text: text, attachments: sent))
        startedHere = true
        (isRunning, statusLine) = (true, "Sending…")
        isSubmitting = false
        do {
            var params: [String: JSONValue] = ["text": .string(outgoing)]
            if queued { params["queued"] = true }
            let answer = try await ask("prompt.submit", params)
            let status = answer.text("status")
            lastSubmitStatus = status
            if status == "queued" { statusLine = "Queued on the gateway" }
            runtime.pushRegistrar?.noteSend(session: storedID, runtime: runtime)
            activity.start(for: self)
        } catch {
            startedHere = false
            isRunning = false
            statusLine = nil
            addFailure(error.localizedDescription)
            // The gateway refusing this message says nothing about the next, so that one may go. A
            // lost line would fail the rest too: they stay queued and go once the chat is back.
            if error is RPCError { drainQueue() }
        }
    }

    /// Interrupts the running turn.
    public func stop() async {
        interruptCause = .stopped
        _ = try? await ask("session.interrupt")
    }

    /// Interrupts the running turn because the Mac app is about to update and restart. The chat says
    /// so, instead of leaving a bare stop.
    public func pauseForUpdate() async {
        interruptCause = .pausedForUpdate
        _ = try? await ask("session.interrupt")
    }

    /// Sends a nudge into the turn that is running.
    public func steer(_ text: String) async {
        do {
            let answer = try await ask("session.steer", ["text": .string(text)])
            addRow(.steer(text: text, status: answer.text("status") ?? "queued"))
        } catch {
            banner = error.localizedDescription
        }
    }

    public func removeQueued(_ id: UUID) {
        for gone in queue where gone.id == id {
            for file in gone.attachments { if let url = file.localURL { try? FileManager.default.removeItem(at: url) } }
        }
        queue = queue.filter { $0.id != id }
    }

    public func updateQueued(_ id: UUID, text: String) {
        for at in queue.indices where queue[at].id == id { queue[at].text = text }
    }

    // MARK: Attachments

    /// Error row text for an attachment that the gateway did not accept.
    ///
    /// If the gateway is missing the helper program for a kind of file, it names that program in its own
    /// terms (say "pdftoppm not installed"), which makes it seem like Nollie broke. Those cases get a plain
    /// explanation plus what still works. Every other error is quoted as it came.
    nonisolated static func attachmentFailure(name: String, kind: AttachmentPreview.Kind = .file, error: Error) -> String {
        let said = error.localizedDescription
        let tellTales = ["not installed", "package required", "no such file", "command not found", "not found: "]
        if !tellTales.contains(where: { said.localizedCaseInsensitiveContains($0) }) {
            return "Attachment \(name) failed: \(said)"
        }
        let missing: String = switch kind {
        case .pdf: "the tool it reads PDFs with (the poppler-utils package). Pictures and text files still go through."
        case .image: "a tool it needs for pictures."
        case .audio, .video, .file: "a tool it needs for this kind of file."
        }
        return "Attachment \(name) was not taken: the gateway is missing \(missing) The gateway said: \(said)"
    }

    /// Sends one staged attachment to the gateway. Files come back as a text reference to add to
    /// the message; pictures and PDFs are attached to the session directly and give none.
    private func upload(_ file: AttachmentPreview) async throws -> String? {
        guard let url = file.localURL, let data = try? Data(contentsOf: url) else { return nil }
        let encoded = JSONValue.string(data.base64EncodedString())
        let name = JSONValue.string(file.name)
        switch file.kind {
        case .image:
            _ = try await ask("image.attach_bytes", ["content_base64": encoded, "filename": name])
        case .pdf:
            _ = try await ask("pdf.attach", ["content_base64": encoded, "filename": name])
        case .audio, .video, .file:
            let mime = UTType(filenameExtension: url.pathExtension).flatMap(\.preferredMIMEType) ?? "application/octet-stream"
            let dataURL = JSONValue.string("data:\(mime);base64,\(data.base64EncodedString())")
            return try await ask("file.attach", ["data_url": dataURL, "name": name]).text("ref_text")
        }
        return nil
    }

    public func stageAttachment(data: Data, name: String, kind: AttachmentPreview.Kind) {
        var (bytes, fileName) = (data, name)
        if kind == .image, let converted = Self.imageTranscoder?(data, name) { (bytes, fileName) = converted }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("staged-\(runtimeID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + "-" + fileName)
        do {
            try bytes.write(to: file)
        } catch {
            banner = "Could not stage \(fileName): \(error.localizedDescription)"
            return
        }
        staged.append(AttachmentPreview(id: file.lastPathComponent, name: fileName, serverPath: nil, kind: kind,
                                        localURL: file, byteCount: bytes.count))
    }

    public func removeStaged(_ id: String) {
        if let url = staged.first(where: { $0.id == id })?.localURL { try? FileManager.default.removeItem(at: url) }
        staged.removeAll { $0.id == id }
    }
}
