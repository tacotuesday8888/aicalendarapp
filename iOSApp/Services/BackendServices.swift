import AuthenticationServices
import CryptoKit
import Foundation
import UIKit
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseAuth)
import FirebaseAuth
#endif
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif
#if canImport(FirebaseStorage)
import FirebaseStorage
#endif
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

actor MemoryDatabaseStore {
    private var storage: [String: [String: Data]]
    private var continuations = [String: [UUID: AsyncStream<[Data]>.Continuation]]()
    private let rootDirectory: URL
    private let logger = AppLogger(category: "local-db")

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootDirectory = appSupport.appendingPathComponent("aicalendarapp-db", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        storage = Self.loadAllFromDisk(from: rootDirectory)
        if !storage.isEmpty {
            logger.info("Loaded \(storage.values.reduce(0) { $0 + $1.count }) records from disk.")
        }
    }

    func save(_ data: Data, path: String, id: String) throws {
        let previousValue = storage[path]?[id]
        var collection = storage[path, default: [:]]
        collection[id] = data
        storage[path] = collection
        do {
            try writeToDisk(data: data, path: path, id: id)
            broadcast(path: path)
        } catch {
            if let previousValue {
                storage[path]?[id] = previousValue
            } else {
                storage[path]?[id] = nil
                if storage[path]?.isEmpty == true {
                    storage[path] = nil
                }
            }
            throw error
        }
    }

    func fetch(path: String, id: String) -> Data? {
        storage[path]?[id]
    }

    func fetchAll(path: String) -> [Data] {
        Array(storage[path, default: [:]].values)
    }

    func delete(path: String, id: String) {
        storage[path]?[id] = nil
        removeFromDisk(path: path, id: id)
        broadcast(path: path)
    }

    func deletePrefix(pathPrefix: String) {
        let normalizedPrefix = pathPrefix.hasSuffix("/") ? pathPrefix : "\(pathPrefix)/"
        let paths = storage.keys.filter { path in
            path == pathPrefix || path.hasPrefix(normalizedPrefix)
        }

        for path in paths {
            storage[path] = nil
            removeDirectoryFromDisk(path: path)
            broadcast(path: path)
        }

        removeDirectoryFromDisk(path: pathPrefix)
    }

    func observe(path: String) -> AsyncStream<[Data]> {
        let token = UUID()
        return AsyncStream { continuation in
            continuations[path, default: [:]][token] = continuation
            continuation.yield(Array(storage[path, default: [:]].values))
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(path: path, token: token) }
            }
        }
    }

    private func removeContinuation(path: String, token: UUID) {
        continuations[path]?[token] = nil
    }

    private func broadcast(path: String) {
        let values = Array(storage[path, default: [:]].values)
        continuations[path]?.values.forEach { $0.yield(values) }
    }

    // MARK: - Disk I/O

    private func directoryURL(for path: String) -> URL {
        let sanitized = path.replacingOccurrences(of: "..", with: "_")
        return rootDirectory.appendingPathComponent(sanitized, isDirectory: true)
    }

    private func fileURL(for path: String, id: String) -> URL {
        let sanitizedID = id.replacingOccurrences(of: "/", with: "_")
        return directoryURL(for: path).appendingPathComponent("\(sanitizedID).json")
    }

    private func writeToDisk(data: Data, path: String, id: String) throws {
        let dir = directoryURL(for: path)
        let file = fileURL(for: path, id: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    private func removeFromDisk(path: String, id: String) {
        let file = fileURL(for: path, id: id)
        try? FileManager.default.removeItem(at: file)
    }

    private func removeDirectoryFromDisk(path: String) {
        let directory = directoryURL(for: path)
        try? FileManager.default.removeItem(at: directory)
    }

    private static func loadAllFromDisk(from rootDirectory: URL) -> [String: [String: Data]] {
        var loadedStorage = [String: [String: Data]]()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return loadedStorage
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "json",
                  let data = try? Data(contentsOf: fileURL) else { continue }

            let id = fileURL.deletingPathExtension().lastPathComponent
            let collectionDir = fileURL.deletingLastPathComponent()
            let relativePath = collectionDir.path().replacingOccurrences(of: rootDirectory.path() + "/", with: "")

            var collection = loadedStorage[relativePath, default: [:]]
            collection[id] = data
            loadedStorage[relativePath] = collection
        }

        return loadedStorage
    }
}

final class DatabaseService: DatabaseServicing {
    static let shared = DatabaseService()

    private let store = MemoryDatabaseStore()

    nonisolated func save<T: Codable>(_ value: T, in collection: AppCollection, id: String, userID: String?) async throws {
        if try await saveToFirebase(value, in: collection, id: id, userID: userID) {
            return
        }
        let data = try JSONEncoder.appEncoder().encode(value)
        try await store.save(data, path: path(for: collection, userID: userID), id: id)
    }

    nonisolated func fetch<T: Codable>(_ type: T.Type, from collection: AppCollection, id: String, userID: String?) async throws -> T {
        if let firebaseValue: T = try await fetchFromFirebase(type, from: collection, id: id, userID: userID) {
            return firebaseValue
        }
        guard let data = await store.fetch(path: path(for: collection, userID: userID), id: id) else {
            throw AppError.dataNotFound
        }
        return try JSONDecoder.appDecoder().decode(T.self, from: data)
    }

    nonisolated func fetchAll<T: Codable>(_ type: T.Type, from collection: AppCollection, userID: String?) async throws -> [T] {
        if let firebaseValues: [T] = try await fetchAllFromFirebase(type, from: collection, userID: userID) {
            return firebaseValues
        }
        let data = await store.fetchAll(path: path(for: collection, userID: userID))
        return try data.map { try JSONDecoder.appDecoder().decode(T.self, from: $0) }
    }

    nonisolated func delete(from collection: AppCollection, id: String, userID: String?) async throws {
        if try await deleteFromFirebase(from: collection, id: id, userID: userID) {
            return
        }
        await store.delete(path: path(for: collection, userID: userID), id: id)
    }

    nonisolated func deleteLocalData(for userID: String) async {
        await store.delete(path: path(for: .users, userID: nil), id: userID)
        await store.deletePrefix(pathPrefix: "users/\(userID)")
    }

    nonisolated func observeAll<T: Codable>(_ type: T.Type, from collection: AppCollection, userID: String?) -> AsyncThrowingStream<[T], Error> {
        if let stream = observeAllFromFirebase(type, from: collection, userID: userID) {
            return stream
        }
        let path = path(for: collection, userID: userID)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await payloads in await store.observe(path: path) {
                    let decoded = payloads.compactMap { try? JSONDecoder.appDecoder().decode(T.self, from: $0) }
                    continuation.yield(decoded)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    nonisolated private func path(for collection: AppCollection, userID: String?) -> String {
        switch collection {
        case .users:
            return "users"
        default:
            return "users/\(userID ?? "preview")/\(collection.rawValue)"
        }
    }

    #if canImport(FirebaseCore) && canImport(FirebaseFirestore)
    nonisolated private var firestore: Firestore? {
        guard FirebaseApp.app() != nil else { return nil }
        return Firestore.firestore()
    }

    nonisolated private func saveToFirebase<T: Codable>(_ value: T, in collection: AppCollection, id: String, userID: String?) async throws -> Bool {
        guard let document = firebaseDocumentReference(in: collection, id: id, userID: userID) else { return false }
        let dictionary = try Self.encodedDictionary(from: value)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.setData(dictionary, merge: true) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        return true
    }

    nonisolated private func fetchFromFirebase<T: Codable>(_ type: T.Type, from collection: AppCollection, id: String, userID: String?) async throws -> T? {
        guard let document = firebaseDocumentReference(in: collection, id: id, userID: userID) else { return nil }
        let snapshot = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DocumentSnapshot, Error>) in
            document.getDocument { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: AppError.dataNotFound)
                }
            }
        }

        guard let data = snapshot.data() else {
            throw AppError.dataNotFound
        }
        return try Self.decode(type, from: data)
    }

    nonisolated private func fetchAllFromFirebase<T: Codable>(_ type: T.Type, from collection: AppCollection, userID: String?) async throws -> [T]? {
        guard let collectionReference = firebaseCollectionReference(for: collection, userID: userID) else { return nil }
        let documents = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[QueryDocumentSnapshot], Error>) in
            collectionReference.getDocuments { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: snapshot?.documents ?? [])
                }
            }
        }
        return try documents.map { document in
            try Self.decode(type, from: document.data())
        }
    }

    nonisolated private func deleteFromFirebase(from collection: AppCollection, id: String, userID: String?) async throws -> Bool {
        guard let document = firebaseDocumentReference(in: collection, id: id, userID: userID) else { return false }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.delete { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        return true
    }

    nonisolated private func observeAllFromFirebase<T: Codable>(_ type: T.Type, from collection: AppCollection, userID: String?) -> AsyncThrowingStream<[T], Error>? {
        guard let collectionReference = firebaseCollectionReference(for: collection, userID: userID) else { return nil }

        let logger = AppLogger(category: "firestore-listener")
        return AsyncThrowingStream { continuation in
            let listener = collectionReference.addSnapshotListener { snapshot, error in
                if let error {
                    logger.error("Snapshot listener error for \(collection.rawValue): \(error.localizedDescription)")
                    continuation.finish(throwing: AppError.network(description: "Live updates failed for \(collection.rawValue)."))
                    return
                }
                guard let snapshot else { return }
                let values = snapshot.documents.compactMap { try? Self.decode(type, from: $0.data()) }
                continuation.yield(values)
            }

            continuation.onTermination = { _ in
                listener.remove()
            }
        }
    }

    nonisolated private func firebaseCollectionReference(for collection: AppCollection, userID: String?) -> CollectionReference? {
        guard let firestore else { return nil }
        switch collection {
        case .users:
            return firestore.collection(AppCollection.users.rawValue)
        default:
            guard let scopedUserID = userID else { return nil }
            return firestore.collection(AppCollection.users.rawValue).document(scopedUserID).collection(collection.rawValue)
        }
    }

    nonisolated private func firebaseDocumentReference(in collection: AppCollection, id: String, userID: String?) -> DocumentReference? {
        firebaseCollectionReference(for: collection, userID: userID)?.document(id)
    }

    nonisolated private static func encodedDictionary<T: Codable>(from value: T) throws -> [String: Any] {
        let data = try JSONEncoder.appEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    nonisolated private static func decode<T: Codable>(_ type: T.Type, from dictionary: [String: Any]) throws -> T {
        let normalized = normalizeForJSON(dictionary) as? [String: Any] ?? dictionary
        let data = try JSONSerialization.data(withJSONObject: normalized, options: [])
        return try JSONDecoder.appDecoder().decode(type, from: data)
    }

    nonisolated private static func normalizeForJSON(_ value: Any) -> Any {
        #if canImport(FirebaseFirestore)
        if let timestamp = value as? Timestamp {
            return ISO8601DateFormatter.appJSON.string(from: timestamp.dateValue())
        }
        #endif

        if let date = value as? Date {
            return ISO8601DateFormatter.appJSON.string(from: date)
        }

        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(normalizeForJSON)
        }

        if let array = value as? [Any] {
            return array.map(normalizeForJSON)
        }

        return value
    }
    #else
    private func saveToFirebase<T: Codable>(_ value: T, in collection: AppCollection, id: String, userID: String?) async throws -> Bool { false }
    private func fetchFromFirebase<T: Codable>(_ type: T.Type, from collection: AppCollection, id: String, userID: String?) async throws -> T? { nil }
    private func fetchAllFromFirebase<T: Codable>(_ type: T.Type, from collection: AppCollection, userID: String?) async throws -> [T]? { nil }
    private func deleteFromFirebase(from collection: AppCollection, id: String, userID: String?) async throws -> Bool { false }
    private func observeAllFromFirebase<T: Codable>(_ type: T.Type, from collection: AppCollection, userID: String?) -> AsyncThrowingStream<[T], Error>? { nil }
    #endif
}


final class StorageService: StorageServicing {
    static let shared = StorageService()

    private let baseURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("aicalendarapp-uploads", isDirectory: true)

    init() {
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true, attributes: nil)
    }

    func upload(data: Data, path: String, contentType: String) async throws -> String {
        let normalizedPath = normalizedStoragePath(for: path)
        if try await uploadToFirebase(data: data, path: normalizedPath, contentType: contentType) {
            return normalizedPath
        }
        let fileURL = baseURL.appendingPathComponent(normalizedPath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try data.write(to: fileURL, options: .atomic)
        return normalizedPath
    }

    func delete(path: String) async throws {
        let normalizedPath = normalizedStoragePath(for: path)
        if try await deleteFromFirebase(path: normalizedPath) {
            return
        }
        let fileURL = baseURL.appendingPathComponent(normalizedPath)
        if FileManager.default.fileExists(atPath: fileURL.path()) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func normalizedStoragePath(for path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "..", with: "_")
    }

    #if canImport(FirebaseCore) && canImport(FirebaseStorage)
    private var storageReference: StorageReference? {
        guard FirebaseApp.app() != nil else { return nil }
        return Storage.storage().reference()
    }

    private func uploadToFirebase(data: Data, path: String, contentType: String) async throws -> Bool {
        guard let reference = storageReference?.child(path) else { return false }
        let metadata = StorageMetadata()
        metadata.contentType = contentType

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.putData(data, metadata: metadata) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        return true
    }

    private func deleteFromFirebase(path: String) async throws -> Bool {
        guard let reference = storageReference?.child(path) else { return false }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.delete { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        return true
    }
    #else
    private func uploadToFirebase(data: Data, path: String, contentType: String) async throws -> Bool { false }
    private func deleteFromFirebase(path: String) async throws -> Bool { false }
    #endif
}

#if DEBUG
actor LocalCredentialStore {
    private let secureStore: KeychainStore

    init(secureStore: KeychainStore = .shared) {
        self.secureStore = secureStore
    }

    func save(password: String, for email: String) throws {
        try secureStore.set(Self.digest(for: password), for: key(for: email))
    }

    func passwordMatches(_ password: String, for email: String) throws -> Bool {
        guard let storedDigest = try secureStore.value(for: key(for: email)) else {
            return false
        }

        return storedDigest == Self.digest(for: password)
    }

    private func key(for email: String) -> String {
        "auth.password.\(email.lowercased())"
    }

    nonisolated private static func digest(for password: String) -> Data {
        Data(SHA256.hash(data: Data(password.utf8)))
    }
}
#endif

actor AuthContinuationStore {
    private var continuations = [UUID: AsyncStream<UserProfile?>.Continuation]()

    func add(_ continuation: AsyncStream<UserProfile?>.Continuation, token: UUID) {
        continuations[token] = continuation
    }

    func remove(token: UUID) {
        continuations[token] = nil
    }

    func yield(_ profile: UserProfile?) {
        continuations.values.forEach { $0.yield(profile) }
    }
}

final class AuthService: AuthServicing {
    static let shared = AuthService()

    var databaseService: DatabaseServicing?
    weak var userService: UserServicing?

    private static let sessionKey = "auth.current_user_id"
    #if DEBUG
    private let credentials = LocalCredentialStore()
    #endif
    private let continuationStore = AuthContinuationStore()
    private let sessionStore: KeychainStore
    private let logger = AppLogger(category: "auth")
    private var currentProfile: UserProfile?
    private var didRestoreSession = false
    #if canImport(FirebaseAuth)
    private var authStateHandle: AuthStateDidChangeListenerHandle?
    #endif

    init(sessionStore: KeychainStore = .shared) {
        self.sessionStore = sessionStore
    }

    var currentUserID: String? {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth)
        if FirebaseApp.app() != nil, let firebaseUserID = Auth.auth().currentUser?.uid {
            return firebaseUserID
        }
        #endif
        return currentProfile?.id
    }

    func authStateStream() -> AsyncStream<UserProfile?> {
        ensureFirebaseAuthListenerIfAvailable()
        let token = UUID()

        if !didRestoreSession {
            didRestoreSession = true
            Task { [weak self] in
                await self?.restoreSession()
            }
        }

        let currentProfile = self.currentProfile
        return AsyncStream { continuation in
            continuation.yield(currentProfile)
            Task { [weak self] in
                await self?.continuationStore.add(continuation, token: token)
            }
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.continuationStore.remove(token: token)
                }
            }
        }
    }

    private func restoreSession() async {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth)
        if FirebaseApp.app() != nil, Auth.auth().currentUser != nil {
            return
        }
        #endif

        #if DEBUG
        guard let savedIDData = try? sessionStore.value(for: Self.sessionKey),
              let savedID = String(data: savedIDData, encoding: .utf8),
              !savedID.isEmpty else {
            return
        }

        do {
            let profile = try await requiredUserService().fetchProfile(for: savedID)
            setCurrentUser(profile)
            logger.info("Restored session for user \(savedID).")
        } catch {
            logger.notice("Could not restore previous session: \(error.localizedDescription)")
            try? sessionStore.deleteValue(for: Self.sessionKey)
        }
        #endif
    }

    func signIn(email: String, password: String) async throws -> UserProfile {
        if let firebaseProfile = try await signInWithFirebaseEmail(email: email, password: password) {
            return firebaseProfile
        }

        #if DEBUG
        guard try await credentials.passwordMatches(password, for: email) else {
            throw AppError.invalidCredentials
        }

        let existingProfile = try await fetchExistingProfile(email: email)
        setCurrentUser(existingProfile)
        return existingProfile
        #else
        throw AppError.integrationUnavailable("FirebaseAuth")
        #endif
    }

    func signUp(email: String, password: String, displayName: String) async throws -> UserProfile {
        if let firebaseProfile = try await signUpWithFirebaseEmail(email: email, password: password, displayName: displayName) {
            return firebaseProfile
        }

        #if DEBUG
        let profile = UserProfile(
            id: UUID().uuidString,
            email: email,
            displayName: displayName,
            academicFocus: "",
            signInProvider: "email",
            assistantOptIn: true,
            selectedCalendarIDs: [],
            createdAt: .now
        )

        try await credentials.save(password: password, for: email)
        try await requiredUserService().saveProfile(profile)
        setCurrentUser(profile)
        return profile
        #else
        throw AppError.integrationUnavailable("FirebaseAuth")
        #endif
    }

    func signInWithApple() async throws -> UserProfile {
        if let firebaseProfile = try await signInWithFirebaseApple() {
            return firebaseProfile
        }

        #if DEBUG
        let result = try await AppleSignInCoordinator().start()
        let profile = UserProfile(
            id: result.userIdentifier,
            email: result.email,
            displayName: result.displayName,
            academicFocus: "",
            signInProvider: "apple",
            assistantOptIn: true,
            selectedCalendarIDs: [],
            createdAt: .now
        )
        try await requiredUserService().saveProfile(profile)
        setCurrentUser(profile)
        return profile
        #else
        throw AppError.integrationUnavailable("FirebaseAuth")
        #endif
    }

    func signInWithGoogle() async throws -> UserProfile {
        if let firebaseProfile = try await signInWithFirebaseGoogle() {
            return firebaseProfile
        }

        #if DEBUG
        #if canImport(GoogleSignIn)
        guard !AppConfiguration.shared.googleClientID.isEmpty else {
            throw AppError.missingConfiguration("GoogleClientID")
        }
        guard let presenter = UIApplication.topViewController() else {
            throw AppError.unknown("Unable to find a view controller for Google sign-in.")
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: AppConfiguration.shared.googleClientID)
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        let user = result.user
        let profile = UserProfile(
            id: user.userID ?? UUID().uuidString,
            email: user.profile?.email ?? "",
            displayName: user.profile?.name ?? "Google User",
            academicFocus: "",
            signInProvider: "google",
            assistantOptIn: true,
            selectedCalendarIDs: [],
            createdAt: .now
        )
        try await requiredUserService().saveProfile(profile)
        setCurrentUser(profile)
        return profile
        #else
        let profile = UserProfile(
            id: UUID().uuidString,
            email: "student@example.com",
            displayName: "Student Planner",
            academicFocus: "",
            signInProvider: "google-demo",
            assistantOptIn: true,
            selectedCalendarIDs: [],
            createdAt: .now
        )
        try await requiredUserService().saveProfile(profile)
        setCurrentUser(profile)
        return profile
        #endif
        #else
        throw AppError.integrationUnavailable("FirebaseAuth")
        #endif
    }

    func signOut() async throws {
        try signOutFromFirebaseIfAvailable()
        setCurrentUser(nil)
        logger.info("Signed out current user.")
    }

    private func fetchExistingProfile(email: String) async throws -> UserProfile {
        guard let databaseService else {
            throw AppError.unknown("Database dependency is unavailable.")
        }

        let profiles = try await databaseService.fetchAll(UserProfile.self, from: .users, userID: nil)
        if let profile = profiles.first(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
            return profile
        }

        throw AppError.invalidCredentials
    }

    private func setCurrentUser(_ profile: UserProfile?) {
        currentProfile = profile

        if let profile {
            try? sessionStore.set(Data(profile.id.utf8), for: Self.sessionKey)
        } else {
            try? sessionStore.deleteValue(for: Self.sessionKey)
        }

        Task {
            await continuationStore.yield(profile)
        }
    }

    private func requiredUserService() throws -> UserServicing {
        guard let userService else {
            throw AppError.missingConfiguration("userService")
        }
        return userService
    }

    #if canImport(FirebaseCore) && canImport(FirebaseAuth)
    private var auth: Auth? {
        guard FirebaseApp.app() != nil else { return nil }
        return Auth.auth()
    }

    private func ensureFirebaseAuthListenerIfAvailable() {
        guard authStateHandle == nil, let auth else { return }
        authStateHandle = auth.addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                await self?.applyFirebaseUser(user)
            }
        }
    }

    private func applyFirebaseUser(_ user: FirebaseAuth.User?) async {
        guard let user else {
            setCurrentUser(nil)
            return
        }

        do {
            let providerID = user.providerData.first?.providerID ?? "firebase"
            let profile = try await resolveProfile(
                for: user,
                provider: providerID,
                emailFallback: user.email,
                displayNameFallback: user.displayName
            )
            setCurrentUser(profile)
        } catch {
            logger.error("Failed to resolve Firebase auth state profile: \(error.localizedDescription)")
            setCurrentUser(makeProfile(
                id: user.uid,
                email: user.email ?? "",
                displayName: user.displayName ?? "Student Planner",
                provider: user.providerData.first?.providerID ?? "firebase",
                createdAt: user.metadata.creationDate ?? .now
            ))
        }
    }

    private func signInWithFirebaseEmail(email: String, password: String) async throws -> UserProfile? {
        guard let auth else { return nil }
        let authResult = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AuthDataResult, Error>) in
            auth.signIn(withEmail: email, password: password) { authResult, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let authResult {
                    continuation.resume(returning: authResult)
                } else {
                    continuation.resume(throwing: AppError.invalidCredentials)
                }
            }
        }

        let profile = try await resolveProfile(
            for: authResult.user,
            provider: "email",
            emailFallback: email,
            displayNameFallback: authResult.user.displayName
        )
        setCurrentUser(profile)
        return profile
    }

    private func signUpWithFirebaseEmail(email: String, password: String, displayName: String) async throws -> UserProfile? {
        guard let auth else { return nil }
        let authResult = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AuthDataResult, Error>) in
            auth.createUser(withEmail: email, password: password) { authResult, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let authResult {
                    continuation.resume(returning: authResult)
                } else {
                    continuation.resume(throwing: AppError.unknown("Unable to create the Firebase account."))
                }
            }
        }

        let changeRequest = authResult.user.createProfileChangeRequest()
        changeRequest.displayName = displayName
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            changeRequest.commitChanges { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        let profile = try await resolveProfile(
            for: authResult.user,
            provider: "email",
            emailFallback: email,
            displayNameFallback: displayName
        )
        setCurrentUser(profile)
        return profile
    }

    private func signInWithFirebaseApple() async throws -> UserProfile? {
        guard auth != nil else { return nil }
        let result = try await AppleSignInCoordinator().start()
        guard let identityToken = result.identityToken, let rawNonce = result.rawNonce else {
            throw AppError.unknown("Apple sign-in did not return the token required for Firebase authentication.")
        }

        let credential = OAuthProvider.appleCredential(
            withIDToken: identityToken,
            rawNonce: rawNonce,
            fullName: result.fullName
        )
        let authResult = try await signInToFirebase(with: credential)
        let profile = try await resolveProfile(
            for: authResult.user,
            provider: "apple",
            emailFallback: result.email,
            displayNameFallback: result.displayName
        )
        setCurrentUser(profile)
        return profile
    }

    private func signInToFirebase(with credential: AuthCredential) async throws -> AuthDataResult {
        guard let auth else {
            throw AppError.integrationUnavailable("FirebaseAuth")
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AuthDataResult, Error>) in
            auth.signIn(with: credential) { authResult, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let authResult {
                    continuation.resume(returning: authResult)
                } else {
                    continuation.resume(throwing: AppError.unknown("Firebase sign-in returned no auth result."))
                }
            }
        }
    }

    private func resolveProfile(
        for user: FirebaseAuth.User,
        provider: String,
        emailFallback: String?,
        displayNameFallback: String?
    ) async throws -> UserProfile {
        do {
            let existingProfile = try await requiredUserService().fetchProfile(for: user.uid)
            return existingProfile
        } catch AppError.dataNotFound {
            // Create an app profile below when Firebase auth exists but app profile does not.
        }

        let profile = makeProfile(
            id: user.uid,
            email: user.email ?? emailFallback ?? "",
            displayName: user.displayName ?? displayNameFallback ?? "Student Planner",
            provider: provider,
            createdAt: user.metadata.creationDate ?? .now
        )
        try await requiredUserService().saveProfile(profile)
        return profile
    }

    private func signOutFromFirebaseIfAvailable() throws {
        guard let auth else { return }
        try auth.signOut()
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
    }
    #else
    private func ensureFirebaseAuthListenerIfAvailable() {}
    private func signInWithFirebaseEmail(email: String, password: String) async throws -> UserProfile? { nil }
    private func signUpWithFirebaseEmail(email: String, password: String, displayName: String) async throws -> UserProfile? { nil }
    private func signInWithFirebaseApple() async throws -> UserProfile? { nil }
    private func signOutFromFirebaseIfAvailable() throws {}
    #endif

    #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(GoogleSignIn)
    private func signInWithFirebaseGoogle() async throws -> UserProfile? {
        guard auth != nil else { return nil }
        guard let presenter = UIApplication.topViewController() else {
            throw AppError.unknown("Unable to find a view controller for Google sign-in.")
        }

        let clientID = FirebaseApp.app()?.options.clientID ?? AppConfiguration.shared.googleClientID
        guard !clientID.isEmpty else {
            throw AppError.missingConfiguration("GoogleClientID")
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AppError.unknown("Google sign-in did not return an ID token.")
        }

        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
        let authResult = try await signInToFirebase(with: credential)
        let profile = try await resolveProfile(
            for: authResult.user,
            provider: "google",
            emailFallback: result.user.profile?.email,
            displayNameFallback: result.user.profile?.name
        )
        setCurrentUser(profile)
        return profile
    }
    #else
    private func signInWithFirebaseGoogle() async throws -> UserProfile? { nil }
    #endif

    private func makeProfile(
        id: String,
        email: String,
        displayName: String,
        provider: String,
        createdAt: Date
    ) -> UserProfile {
        UserProfile(
            id: id,
            email: email,
            displayName: displayName.isEmpty ? "Student Planner" : displayName,
            academicFocus: "",
            signInProvider: provider,
            assistantOptIn: true,
            selectedCalendarIDs: [],
            createdAt: createdAt
        )
    }
}

final class UserService: UserServicing {
    static let shared = UserService()

    var databaseService: DatabaseServicing?

    func fetchProfile(for userID: String) async throws -> UserProfile {
        guard let databaseService else {
            throw AppError.unknown("Database dependency is unavailable.")
        }

        return try await databaseService.fetch(UserProfile.self, from: .users, id: userID, userID: nil)
    }

    func saveProfile(_ profile: UserProfile) async throws {
        guard let databaseService else {
            throw AppError.unknown("Database dependency is unavailable.")
        }

        try await databaseService.save(profile, in: .users, id: profile.id, userID: nil)
    }

    func fetchOnboardingState(for userID: String) async throws -> OnboardingState {
        guard let databaseService else {
            throw AppError.unknown("Database dependency is unavailable.")
        }

        do {
            return try await databaseService.fetch(OnboardingState.self, from: .onboarding, id: "state", userID: userID)
        } catch AppError.dataNotFound {
            return OnboardingState()
        } catch {
            throw AppError.wrap(error, fallback: "Unable to load onboarding state.")
        }
    }

    func saveOnboardingState(_ state: OnboardingState, for userID: String) async throws {
        guard let databaseService else {
            throw AppError.unknown("Database dependency is unavailable.")
        }

        try await databaseService.save(state, in: .onboarding, id: "state", userID: userID)
    }
}

private final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<AppleSignInResult, Error>?
    private var currentNonce: String?

    struct AppleSignInResult {
        let userIdentifier: String
        let email: String
        let displayName: String
        let identityToken: String?
        let rawNonce: String?
        let fullName: PersonNameComponents?
    }

    func start() async throws -> AppleSignInResult {
        let nonce = try Self.randomNonceString()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.email, .fullName]
            currentNonce = nonce
            request.nonce = Self.sha256(nonce)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            continuation?.resume(throwing: AppError.unknown("Apple sign-in returned an invalid credential."))
            continuation = nil
            return
        }

        let formatter = PersonNameComponentsFormatter()
        let displayName = formatter
            .string(from: credential.fullName ?? PersonNameComponents())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identityToken = credential.identityToken.flatMap { String(data: $0, encoding: .utf8) }

        continuation?.resume(returning: AppleSignInResult(
            userIdentifier: credential.user,
            email: credential.email ?? "",
            displayName: displayName.isEmpty ? "Apple User" : displayName,
            identityToken: identityToken,
            rawNonce: currentNonce,
            fullName: credential.fullName
        ))
        currentNonce = nil
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        currentNonce = nil
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func randomNonceString(length: Int = 32) throws -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            var batch = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, batch.count, &batch)
            if status != errSecSuccess {
                throw AppError.unknown("Unable to generate Apple sign-in nonce (SecRandomCopyBytes status \(status)). Try again.")
            }

            for random in batch {
                if remainingLength == 0 {
                    break
                }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }

        return result
    }
}

private extension UIApplication {
    static func topViewController(
        base: UIViewController? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    ) -> UIViewController? {
        if let navigationController = base as? UINavigationController {
            return topViewController(base: navigationController.visibleViewController)
        }
        if let tabBarController = base as? UITabBarController, let selected = tabBarController.selectedViewController {
            return topViewController(base: selected)
        }
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
}
