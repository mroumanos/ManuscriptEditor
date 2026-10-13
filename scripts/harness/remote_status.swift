import Foundation
@testable import ManuscriptEditor

// Overview offers Create only for a repository that is absent from the
// account's own namespace.  Every other outcome of the probe — a rejected
// token, a rate limit, an empty repository, a GitHub error, another owner's
// name — keeps Save|Load, because Create over an existing repository would
// push into it.
typealias State = GitHubBackendService.RepositoryState
typealias Status = ManuscriptStore.RemoteRepoStatus
var failures = 0
func check(_ label: String, _ got: Status, _ want: Status) {
    let ok = got == want
    print("\(ok ? "PASS" : "FAIL")  \(label)" + (ok ? "" : "  got \(got), want \(want)"))
    if !ok { failures += 1 }
}
func status(_ r: Result<State, Error>, owner: String = "ada", login: String = "ada") -> Status {
    ManuscriptStore.remoteStatus(for: r, owner: owner, login: login)
}
func isUnreachable(_ s: Status) -> Bool { if case .unreachable = s { return true }; return false }

check("blank namespace match, repository absent → Create", status(.success(.absent)), .missing)
check("absent under a different casing of the login → Create", status(.success(.absent), owner: "Ada"), .missing)
check("absent under another owner → not Create", isUnreachable(status(.success(.absent), owner: "collaborator")) ? .unreachable("") : .valid, .unreachable(""))
check("empty repository → Save|Load", status(.success(.empty)), .valid)
check("repository with commits → Save|Load", status(.success(.present)), .valid)
check("offline → leave the UI alone", status(.failure(URLError(.notConnectedToInternet))), .unknown)
for code in [401, 403, 409, 422, 500, 502] {
    let s = status(.failure(GitHubBackendError.http(code, "x")))
    check("HTTP \(code) → never Create", isUnreachable(s) ? .unreachable("") : s, .unreachable(""))
}
let bad = status(.failure(GitHubBackendError.badResponse("garbled")))
check("garbled response → never Create", isUnreachable(bad) ? .unreachable("") : bad, .unreachable(""))
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
