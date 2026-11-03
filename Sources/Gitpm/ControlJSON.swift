import Foundation

// Explicit JSON adapters for the pinned UniFFI records. Field names follow the Swift API.
// Enums use {"type": caseName, ...associatedValues}; empty optionals encode as null.

extension AuthCheck: Encodable {
    private enum CodingKeys: String, CodingKey { case source, message }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(source, forKey: .source)
        try values.encode(message, forKey: .message)
    }
}

extension CatalogBuild: Encodable {
    private enum CodingKeys: String, CodingKey { case url, sha256 }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(url, forKey: .url)
        try values.encode(sha256, forKey: .sha256)
    }
}

extension CatalogLinks: Encodable {
    private enum CodingKeys: String, CodingKey { case schema, directories }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schema, forKey: .schema)
        try values.encode(directories, forKey: .directories)
    }
}

extension CatalogOverview: Encodable {
    private enum CodingKeys: String, CodingKey { case location, remote, verified, items, truncated }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(location, forKey: .location)
        try values.encode(remote, forKey: .remote)
        try values.encode(verified, forKey: .verified)
        try values.encode(items, forKey: .items)
        try values.encode(truncated, forKey: .truncated)
    }
}

extension CatalogRegistration: Encodable {
    private enum CodingKeys: String, CodingKey { case release, releaseJson, warnings }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(release, forKey: .release)
        try values.encode(releaseJson, forKey: .releaseJson)
        try values.encode(warnings, forKey: .warnings)
    }
}

extension CatalogRelease: Encodable {
    private enum CodingKeys: String, CodingKey { case id, version, source, commit, reference, fileCount, forkOf, replaces, dependencies, buildUrl, buildSha256, path, title, description, provides, tags }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(version, forKey: .version)
        try values.encode(source, forKey: .source)
        try values.encode(commit, forKey: .commit)
        try values.encode(reference, forKey: .reference)
        try values.encode(fileCount, forKey: .fileCount)
        try values.encode(forkOf, forKey: .forkOf)
        try values.encode(replaces, forKey: .replaces)
        try values.encode(dependencies, forKey: .dependencies)
        try values.encode(buildUrl, forKey: .buildUrl)
        try values.encode(buildSha256, forKey: .buildSha256)
        try values.encode(path, forKey: .path)
        try values.encode(title, forKey: .title)
        try values.encode(description, forKey: .description)
        try values.encode(provides, forKey: .provides)
        try values.encode(tags, forKey: .tags)
    }
}

extension CatalogSkippedTag: Encodable {
    private enum CodingKeys: String, CodingKey { case source, tag }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(source, forKey: .source)
        try values.encode(tag, forKey: .tag)
    }
}

extension CatalogUpdate: Encodable {
    private enum CodingKeys: String, CodingKey { case releases, sources, skipped, warnings }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(releases, forKey: .releases)
        try values.encode(sources, forKey: .sources)
        try values.encode(skipped, forKey: .skipped)
        try values.encode(warnings, forKey: .warnings)
    }
}

extension CheckReport: Encodable {
    private enum CodingKeys: String, CodingKey { case rows, catalogVerified, replacements, unsatisfied }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(rows, forKey: .rows)
        try values.encode(catalogVerified, forKey: .catalogVerified)
        try values.encode(replacements, forKey: .replacements)
        try values.encode(unsatisfied, forKey: .unsatisfied)
    }
}

extension CheckRow: Encodable {
    private enum CodingKeys: String, CodingKey { case id, installed, latest, enabled, updateAvailable, status, statusMessage, source, mode, problem, originLatest, upstream, major, prerelease }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(installed, forKey: .installed)
        try values.encode(latest, forKey: .latest)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(updateAvailable, forKey: .updateAvailable)
        try values.encode(status, forKey: .status)
        try values.encode(statusMessage, forKey: .statusMessage)
        try values.encode(source, forKey: .source)
        try values.encode(mode, forKey: .mode)
        try values.encode(problem, forKey: .problem)
        try values.encode(originLatest, forKey: .originLatest)
        try values.encode(upstream, forKey: .upstream)
        try values.encode(major, forKey: .major)
        try values.encode(prerelease, forKey: .prerelease)
    }
}

extension CommitResult: Encodable {
    private enum CodingKeys: String, CodingKey { case package, version, tag }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(package, forKey: .package)
        try values.encode(version, forKey: .version)
        try values.encode(tag, forKey: .tag)
    }
}

extension DependencyStatus: Encodable {
    private enum CodingKeys: String, CodingKey { case id, requirement, provider, version, satisfied, problem }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(requirement, forKey: .requirement)
        try values.encode(provider, forKey: .provider)
        try values.encode(version, forKey: .version)
        try values.encode(satisfied, forKey: .satisfied)
        try values.encode(problem, forKey: .problem)
    }
}

extension DistSync: Encodable {
    private enum CodingKeys: String, CodingKey { case deployed, removed, unmanaged, skipped, warnings }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(deployed, forKey: .deployed)
        try values.encode(removed, forKey: .removed)
        try values.encode(unmanaged, forKey: .unmanaged)
        try values.encode(skipped, forKey: .skipped)
        try values.encode(warnings, forKey: .warnings)
    }
}

extension ForgetResult: Encodable {
    private enum CodingKeys: String, CodingKey { case cloneKept, dist }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(cloneKept, forKey: .cloneKept)
        try values.encode(dist, forKey: .dist)
    }
}

extension ForkOf: Encodable {
    private enum CodingKeys: String, CodingKey { case id, version, commit, source }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(version, forKey: .version)
        try values.encode(commit, forKey: .commit)
        try values.encode(source, forKey: .source)
    }
}

extension ForkResult: Encodable {
    private enum CodingKeys: String, CodingKey { case id, path }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(path, forKey: .path)
    }
}

extension ForkedPackage: Encodable {
    private enum CodingKeys: String, CodingKey { case original, id, path, version }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(original, forKey: .original)
        try values.encode(id, forKey: .id)
        try values.encode(path, forKey: .path)
        try values.encode(version, forKey: .version)
    }
}

extension HeldBack: Encodable {
    private enum CodingKeys: String, CodingKey { case id, selected, latest, reason, message }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(selected, forKey: .selected)
        try values.encode(latest, forKey: .latest)
        try values.encode(reason, forKey: .reason)
        try values.encode(message, forKey: .message)
    }
}

extension IncompatibleConsumer: Encodable {
    private enum CodingKeys: String, CodingKey { case id, requirement }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(requirement, forKey: .requirement)
    }
}

extension InitOptions: Encodable {
    private enum CodingKeys: String, CodingKey { case multi, release }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(multi, forKey: .multi)
        try values.encode(release, forKey: .release)
    }
}

extension InitResult: Encodable {
    private enum CodingKeys: String, CodingKey { case id, repo, folder, version, newRepository, tag }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(repo, forKey: .repo)
        try values.encode(folder, forKey: .folder)
        try values.encode(version, forKey: .version)
        try values.encode(newRepository, forKey: .newRepository)
        try values.encode(tag, forKey: .tag)
    }
}

extension InstallResult: Encodable {
    private enum CodingKeys: String, CodingKey { case id, source, current, forkOf, alreadyInstalled, available, mode, requestedMode, skipped, warnings, enabled, dependencies, dist }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(source, forKey: .source)
        try values.encode(current, forKey: .current)
        try values.encode(forkOf, forKey: .forkOf)
        try values.encode(alreadyInstalled, forKey: .alreadyInstalled)
        try values.encode(available, forKey: .available)
        try values.encode(mode, forKey: .mode)
        try values.encode(requestedMode, forKey: .requestedMode)
        try values.encode(skipped, forKey: .skipped)
        try values.encode(warnings, forKey: .warnings)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(dependencies, forKey: .dependencies)
        try values.encode(dist, forKey: .dist)
    }
}

extension InstalledDependency: Encodable {
    private enum CodingKeys: String, CodingKey { case id, source, current, enabled, warnings }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(source, forKey: .source)
        try values.encode(current, forKey: .current)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(warnings, forKey: .warnings)
    }
}

extension InstalledPackage: Encodable {
    private enum CodingKeys: String, CodingKey { case id, name, installed, source, current, version, previous, enabled, mode, active, forkOf, replaces, catalog, path, clone, title, description, provides, tags, dependencies, replacing, dependents }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(installed, forKey: .installed)
        try values.encode(source, forKey: .source)
        try values.encode(current, forKey: .current)
        try values.encode(version, forKey: .version)
        try values.encode(previous, forKey: .previous)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(mode, forKey: .mode)
        try values.encode(active, forKey: .active)
        try values.encode(forkOf, forKey: .forkOf)
        try values.encode(replaces, forKey: .replaces)
        try values.encode(catalog, forKey: .catalog)
        try values.encode(path, forKey: .path)
        try values.encode(clone, forKey: .clone)
        try values.encode(title, forKey: .title)
        try values.encode(description, forKey: .description)
        try values.encode(provides, forKey: .provides)
        try values.encode(tags, forKey: .tags)
        try values.encode(dependencies, forKey: .dependencies)
        try values.encode(replacing, forKey: .replacing)
        try values.encode(dependents, forKey: .dependents)
    }
}

extension LinkDescriptor: Encodable {
    private enum CodingKeys: String, CodingKey { case packageRoot, target, discovery }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(packageRoot, forKey: .packageRoot)
        try values.encode(target, forKey: .target)
        try values.encode(discovery, forKey: .discovery)
    }
}

extension LinkDiscovery: Encodable {
    private enum CodingKeys: String, CodingKey { case forkOf }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(forkOf, forKey: .forkOf)
    }
}

extension LinkResult: Encodable {
    private enum CodingKeys: String, CodingKey { case id, version, mode, refreshed, dist }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(version, forKey: .version)
        try values.encode(mode, forKey: .mode)
        try values.encode(refreshed, forKey: .refreshed)
        try values.encode(dist, forKey: .dist)
    }
}

extension ListView: Encodable {
    private enum CodingKeys: String, CodingKey { case format, packages, replacements, forgotten, resolved }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(format, forKey: .format)
        try values.encode(packages, forKey: .packages)
        try values.encode(replacements, forKey: .replacements)
        try values.encode(forgotten, forKey: .forgotten)
        try values.encode(resolved, forKey: .resolved)
    }
}

extension ManagerOptions: Encodable {
    private enum CodingKeys: String, CodingKey { case catalog, customSsh }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(catalog, forKey: .catalog)
        try values.encode(customSsh, forKey: .customSsh)
    }
}

extension PackageDetails: Encodable {
    private enum CodingKeys: String, CodingKey { case id, name, version, path, forkOf, dependencies, installed }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(version, forKey: .version)
        try values.encode(path, forKey: .path)
        try values.encode(forkOf, forKey: .forkOf)
        try values.encode(dependencies, forKey: .dependencies)
        try values.encode(installed, forKey: .installed)
    }
}

extension PackageFork: Encodable {
    private enum CodingKeys: String, CodingKey { case path, created, commit, packages }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(path, forKey: .path)
        try values.encode(created, forKey: .created)
        try values.encode(commit, forKey: .commit)
        try values.encode(packages, forKey: .packages)
    }
}

extension PackageRecord: Encodable {
    private enum CodingKeys: String, CodingKey { case name, source, current, version, previous, enabled, mode, forkOf, dependencies, replaces, catalog, clone, path, title, description, provides, tags }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(source, forKey: .source)
        try values.encode(current, forKey: .current)
        try values.encode(version, forKey: .version)
        try values.encode(previous, forKey: .previous)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(mode, forKey: .mode)
        try values.encode(forkOf, forKey: .forkOf)
        try values.encode(dependencies, forKey: .dependencies)
        try values.encode(replaces, forKey: .replaces)
        try values.encode(catalog, forKey: .catalog)
        try values.encode(clone, forKey: .clone)
        try values.encode(path, forKey: .path)
        try values.encode(title, forKey: .title)
        try values.encode(description, forKey: .description)
        try values.encode(provides, forKey: .provides)
        try values.encode(tags, forKey: .tags)
    }
}

extension PackageSummary: Encodable {
    private enum CodingKeys: String, CodingKey { case id, source, versions, latest, title, description, provides, tags }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(source, forKey: .source)
        try values.encode(versions, forKey: .versions)
        try values.encode(latest, forKey: .latest)
        try values.encode(title, forKey: .title)
        try values.encode(description, forKey: .description)
        try values.encode(provides, forKey: .provides)
        try values.encode(tags, forKey: .tags)
    }
}

extension ReplacementCheck: Encodable {
    private enum CodingKeys: String, CodingKey { case plan, issues, missing, resolutionError }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(plan, forKey: .plan)
        try values.encode(issues, forKey: .issues)
        try values.encode(missing, forKey: .missing)
        try values.encode(resolutionError, forKey: .resolutionError)
    }
}

extension ReplacementIssue: Encodable {
    private enum CodingKeys: String, CodingKey { case consumer, dependency }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(consumer, forKey: .consumer)
        try values.encode(dependency, forKey: .dependency)
    }
}

extension ReplacementPlan: Encodable {
    private enum CodingKeys: String, CodingKey { case original, provider, version, current, consumers, incompatible, installedVersion, dist }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(original, forKey: .original)
        try values.encode(provider, forKey: .provider)
        try values.encode(version, forKey: .version)
        try values.encode(current, forKey: .current)
        try values.encode(consumers, forKey: .consumers)
        try values.encode(incompatible, forKey: .incompatible)
        try values.encode(installedVersion, forKey: .installedVersion)
        try values.encode(dist, forKey: .dist)
    }
}

extension ReplacementResolution: Encodable {
    private enum CodingKeys: String, CodingKey { case installed, check, dist }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(installed, forKey: .installed)
        try values.encode(check, forKey: .check)
        try values.encode(dist, forKey: .dist)
    }
}

extension Replaces: Encodable {
    private enum CodingKeys: String, CodingKey { case id, version }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(version, forKey: .version)
    }
}

extension Revision: Encodable {
    private enum CodingKeys: String, CodingKey { case version, commit, mode }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(commit, forKey: .commit)
        try values.encode(mode, forKey: .mode)
    }
}

extension RevisionChange: Encodable {
    private enum CodingKeys: String, CodingKey { case id, from, to, changed, major, warnings, skipped, unchangedReason, mode, detached, dist }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(from, forKey: .from)
        try values.encode(to, forKey: .to)
        try values.encode(changed, forKey: .changed)
        try values.encode(major, forKey: .major)
        try values.encode(warnings, forKey: .warnings)
        try values.encode(skipped, forKey: .skipped)
        try values.encode(unchangedReason, forKey: .unchangedReason)
        try values.encode(mode, forKey: .mode)
        try values.encode(detached, forKey: .detached)
        try values.encode(dist, forKey: .dist)
    }
}

extension SkippedDist: Encodable {
    private enum CodingKeys: String, CodingKey { case id, reason, cloneMissing, link }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(reason, forKey: .reason)
        try values.encode(cloneMissing, forKey: .cloneMissing)
        try values.encode(link, forKey: .link)
    }
}

extension SkippedTag: Encodable {
    private enum CodingKeys: String, CodingKey { case name, version, reason }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(version, forKey: .version)
        try values.encode(reason, forKey: .reason)
    }
}

extension Unchanged: Encodable {
    private enum CodingKeys: String, CodingKey { case id, version, reason, message, warnings }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(version, forKey: .version)
        try values.encode(reason, forKey: .reason)
        try values.encode(message, forKey: .message)
        try values.encode(warnings, forKey: .warnings)
    }
}

extension UninstallPlan: Encodable {
    private enum CodingKeys: String, CodingKey { case id, registered, deletes, lostWork, dependents, dependencyConflict }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(registered, forKey: .registered)
        try values.encode(deletes, forKey: .deletes)
        try values.encode(lostWork, forKey: .lostWork)
        try values.encode(dependents, forKey: .dependents)
        try values.encode(dependencyConflict, forKey: .dependencyConflict)
    }
}

extension UnsatisfiedDependency: Encodable {
    private enum CodingKeys: String, CodingKey { case package, dependency, requirement, problem }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(package, forKey: .package)
        try values.encode(dependency, forKey: .dependency)
        try values.encode(requirement, forKey: .requirement)
        try values.encode(problem, forKey: .problem)
    }
}

extension UpdateAllPlan: Encodable {
    private enum CodingKeys: String, CodingKey { case updates, installs, keptBack, unchanged, skipped, dist }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(updates, forKey: .updates)
        try values.encode(installs, forKey: .installs)
        try values.encode(keptBack, forKey: .keptBack)
        try values.encode(unchanged, forKey: .unchanged)
        try values.encode(skipped, forKey: .skipped)
        try values.encode(dist, forKey: .dist)
    }
}

extension Upstream: Encodable {
    private enum CodingKeys: String, CodingKey { case id, base, latest, newer, source, problem }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(base, forKey: .base)
        try values.encode(latest, forKey: .latest)
        try values.encode(newer, forKey: .newer)
        try values.encode(source, forKey: .source)
        try values.encode(problem, forKey: .problem)
    }
}

extension CheckSource: Encodable {
    private enum CodingKeys: String, CodingKey { case type }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .catalog:
            try values.encode("catalog", forKey: .type)
        case .origin:
            try values.encode("origin", forKey: .type)
        }
    }
}

extension CheckStatus: Encodable {
    private enum CodingKeys: String, CodingKey { case type }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .differentSource:
            try values.encode("differentSource", forKey: .type)
        case .invalidCatalogData:
            try values.encode("invalidCatalogData", forKey: .type)
        case .noVersions:
            try values.encode("noVersions", forKey: .type)
        case .uncomparableVersion:
            try values.encode("uncomparableVersion", forKey: .type)
        case .sameVersionDifferentCommit:
            try values.encode("sameVersionDifferentCommit", forKey: .type)
        case .updateAvailable:
            try values.encode("updateAvailable", forKey: .type)
        case .upToDate:
            try values.encode("upToDate", forKey: .type)
        case .newerThanCatalog:
            try values.encode("newerThanCatalog", forKey: .type)
        case .otherCatalog:
            try values.encode("otherCatalog", forKey: .type)
        case .newerThanOrigin:
            try values.encode("newerThanOrigin", forKey: .type)
        case .noReleases:
            try values.encode("noReleases", forKey: .type)
        case .originUnreachable:
            try values.encode("originUnreachable", forKey: .type)
        case .pinned:
            try values.encode("pinned", forKey: .type)
        case .upstreamNotInCatalog:
            try values.encode("upstreamNotInCatalog", forKey: .type)
        }
    }
}

extension DependencyEdit: Encodable {
    private enum CodingKeys: String, CodingKey { case type, dependency, requirement, newDependency }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .add(let dependency, let requirement):
            try values.encode("add", forKey: .type)
            try values.encode(dependency, forKey: .dependency)
            try values.encode(requirement, forKey: .requirement)
        case .update(let dependency, let newDependency, let requirement):
            try values.encode("update", forKey: .type)
            try values.encode(dependency, forKey: .dependency)
            try values.encode(newDependency, forKey: .newDependency)
            try values.encode(requirement, forKey: .requirement)
        case .remove(let dependency):
            try values.encode("remove", forKey: .type)
            try values.encode(dependency, forKey: .dependency)
        }
    }
}

extension HeldBackReason: Encodable {
    private enum CodingKeys: String, CodingKey { case type, dependency, requirement, original }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .constraints:
            try values.encode("constraints", forKey: .type)
        case .missingDependency(let dependency, let requirement):
            try values.encode("missingDependency", forKey: .type)
            try values.encode(dependency, forKey: .dependency)
            try values.encode(requirement, forKey: .requirement)
        case .noLongerReplaces(let original):
            try values.encode("noLongerReplaces", forKey: .type)
            try values.encode(original, forKey: .original)
        }
    }
}

extension InstallTarget: Encodable {
    private enum CodingKeys: String, CodingKey { case type, reference }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .release:
            try values.encode("release", forKey: .type)
        case .ref(let reference):
            try values.encode("ref", forKey: .type)
            try values.encode(reference, forKey: .reference)
        case .dev:
            try values.encode("dev", forKey: .type)
        }
    }
}

extension LostWork: Encodable {
    private enum CodingKeys: String, CodingKey { case type, path, head, recorded, commit, summary, name, commits, entry }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .modified(let path):
            try values.encode("modified", forKey: .type)
            try values.encode(path, forKey: .path)
        case .untracked(let path):
            try values.encode("untracked", forKey: .type)
            try values.encode(path, forKey: .path)
        case .ignored(let path):
            try values.encode("ignored", forKey: .type)
            try values.encode(path, forKey: .path)
        case .headMoved(let head, let recorded):
            try values.encode("headMoved", forKey: .type)
            try values.encode(head, forKey: .head)
            try values.encode(recorded, forKey: .recorded)
        case .unpublishedCommit(let commit, let summary):
            try values.encode("unpublishedCommit", forKey: .type)
            try values.encode(commit, forKey: .commit)
            try values.encode(summary, forKey: .summary)
        case .unpublishedBranch(let name, let commits):
            try values.encode("unpublishedBranch", forKey: .type)
            try values.encode(name, forKey: .name)
            try values.encode(commits, forKey: .commits)
        case .unpublishedTag(let name):
            try values.encode("unpublishedTag", forKey: .type)
            try values.encode(name, forKey: .name)
        case .stash(let entry):
            try values.encode("stash", forKey: .type)
            try values.encode(entry, forKey: .entry)
        }
    }
}

extension Mode: Encodable {
    private enum CodingKeys: String, CodingKey { case type, reference, name, descriptor }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .release:
            try values.encode("release", forKey: .type)
        case .pinned(let reference):
            try values.encode("pinned", forKey: .type)
            try values.encode(reference, forKey: .reference)
        case .branch(let name):
            try values.encode("branch", forKey: .type)
            try values.encode(name, forKey: .name)
        case .link(let descriptor):
            try values.encode("link", forKey: .type)
            try values.encode(descriptor, forKey: .descriptor)
        }
    }
}

extension OverviewItem: Encodable {
    private enum CodingKeys: String, CodingKey { case type, depth, name, package }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .directory(let depth, let name):
            try values.encode("directory", forKey: .type)
            try values.encode(depth, forKey: .depth)
            try values.encode(name, forKey: .name)
        case .empty(let depth):
            try values.encode("empty", forKey: .type)
            try values.encode(depth, forKey: .depth)
        case .package(let depth, let package):
            try values.encode("package", forKey: .type)
            try values.encode(depth, forKey: .depth)
            try values.encode(package, forKey: .package)
        }
    }
}

extension Target: Encodable {
    private enum CodingKeys: String, CodingKey { case type, reference }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .release:
            try values.encode("release", forKey: .type)
        case .ref(let reference):
            try values.encode("ref", forKey: .type)
            try values.encode(reference, forKey: .reference)
        case .dev:
            try values.encode("dev", forKey: .type)
        case .recorded:
            try values.encode("recorded", forKey: .type)
        }
    }
}

extension UnchangedReason: Encodable {
    private enum CodingKeys: String, CodingKey { case type, availability, dependencyProblems, reference, branch, dependency, problem, version, reason }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .devLinked(let availability, let dependencyProblems):
            try values.encode("devLinked", forKey: .type)
            try values.encode(availability, forKey: .availability)
            try values.encode(dependencyProblems, forKey: .dependencyProblems)
        case .pinned(let reference):
            try values.encode("pinned", forKey: .type)
            try values.encode(reference, forKey: .reference)
        case .diverged(let branch):
            try values.encode("diverged", forKey: .type)
            try values.encode(branch, forKey: .branch)
        case .branchGone(let branch):
            try values.encode("branchGone", forKey: .type)
            try values.encode(branch, forKey: .branch)
        case .brokenDependency(let dependency, let problem):
            try values.encode("brokenDependency", forKey: .type)
            try values.encode(dependency, forKey: .dependency)
            try values.encode(problem, forKey: .problem)
        case .notInCatalog(let version):
            try values.encode("notInCatalog", forKey: .type)
            try values.encode(version, forKey: .version)
        case .catalogUnavailable(let reason):
            try values.encode("catalogUnavailable", forKey: .type)
            try values.encode(reason, forKey: .reason)
        }
    }
}


extension PluginManagerFailure {
    public var controlJSON: [String: Any] {
        var result: [String: Any] = ["code": kind, "kind": kind, "message": message,
                                     "plugins": plugins]
        if let id { result["id"] = id }
        // Lost-work records are explicit Encodable values with the same schema accepted by uninstall.
        result["lostWork"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(lostWork))) ?? []
        return result
    }
}
