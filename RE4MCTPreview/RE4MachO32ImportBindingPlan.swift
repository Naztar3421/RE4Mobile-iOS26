import Foundation

public enum RE4MachO32ImportFamily: String, CaseIterable, Hashable {
    case cRuntime = "C runtime / memory"
    case objectiveCRuntime = "Objective-C runtime"
    case cxxRuntime = "C++ ABI / runtime"
    case appleFrameworks = "Apple framework APIs"
    case gameOrEngine = "Game / engine symbols"
    case unclassified = "Other / needs review"
}
public enum RE4MachO32ImportSiteKind: String, Hashable {
    case nonLazyPointer = "non-lazy pointer"
    case lazyPointer = "lazy pointer"
    case symbolStub = "symbol stub"
    case otherIndirect = "other indirect section"
}
public struct RE4MachO32ImportBindingSite {
    public let symbolName: String
    public let family: RE4MachO32ImportFamily
    public let sectionName: String
    public let sectionType: UInt32
    public let siteAddress: UInt32
    public let entrySize: UInt32
    public let kind: RE4MachO32ImportSiteKind
}
public struct RE4MachO32ImportSymbolPlan {
    public let name: String
    public let family: RE4MachO32ImportFamily
    public let sites: [RE4MachO32ImportBindingSite]
}
public struct RE4MachO32ImportBindingPlan {
    public let architectureName: String
    public let siteCount: Int
    public let symbolPlans: [RE4MachO32ImportSymbolPlan]
    public let siteKindCounts: [RE4MachO32ImportSiteKind: Int]
    public let familySymbolCounts: [RE4MachO32ImportFamily: Int]
    public let outOfSegmentSites: [RE4MachO32ImportBindingSite]
    public let hasLegacyIndirectTable: Bool
    public let dyldBindRecordCount: Int

    public var report: String {
        var lines = [
            "Mach-O HLE import binding plan PASS",
            "Architecture: \(architectureName)",
            "Binding model: \(hasLegacyIndirectTable ? "LC_DYSYMTAB indirect-symbol table" : "symbol inventory only")",
            "Indirect import sites: \(siteCount)",
            "Unique indirect symbols: \(symbolPlans.count)",
            "dyld bind records: \(dyldBindRecordCount)",
            "Sites outside segment mappings: \(outOfSegmentSites.count)",
            "",
            "[Unique symbols by family]"
        ]
        for family in RE4MachO32ImportFamily.allCases {
            lines.append("\(family.rawValue): \(familySymbolCounts[family, default: 0])")
        }
        lines += ["", "[Import site kinds]"]
        for kind in [RE4MachO32ImportSiteKind.nonLazyPointer, .lazyPointer, .symbolStub, .otherIndirect] {
            lines.append("\(kind.rawValue): \(siteKindCounts[kind, default: 0])")
        }
        let review = symbolPlans.filter { $0.family == .unclassified }.map(\.name).sorted()
        lines += ["", "[Examples requiring review]"]
        lines += review.prefix(24)
        if review.isEmpty { lines.append("(none)") }
        else if review.count > 24 { lines.append("… plus \(review.count - 24) more") }
        lines += ["", "Inventory/plan only: no guest pointer was patched, no thunk was allocated, and no import was executed."]
        return lines.joined(separator: "\n")
    }
}

public enum RE4MachO32ImportBindingPlanner {
    // Preliminary families for HLE planning only; these are not claims of implementation.
    private static let cRuntime: Set<String> = [
        "_malloc","_calloc","_realloc","_free","_memcpy","_memmove","_memset","_memcmp",
        "_memchr","_strlen","_strnlen","_strcmp","_strncmp","_strcpy","_strncpy","_strcat",
        "_strncat","_strchr","_strrchr","_strstr","_strdup","_strtol","_strtoul","_strtod",
        "_atoi","_atof","_snprintf","_sprintf","_vsnprintf","_printf","_fprintf","_vfprintf",
        "_puts","_putchar","_fopen","_fclose","_fread","_fwrite","_fseek","_ftell","_ferror",
        "_feof","_fflush","_open","_close","_read","_write","_lseek","_stat","_fstat","_access",
        "_getenv","_setenv","_unsetenv","_abort","_exit","_atexit","_qsort","_bsearch","_rand",
        "_srand","_time","_localtime","_gmtime","_difftime","_clock","_gettimeofday","_tolower",
        "_toupper","_floor","_ceil","_sqrt","_pow","_sin","_cos","_tan","_atan2","_fabs","_exp",
        "_log","_modf","_ldexp","_strerror","_perror","_remove","_rename","_unlink","_mkdir",
        "_rmdir","_chdir","_getcwd","_pthread_mutex_lock","_pthread_mutex_unlock","_pthread_mutex_init",
        "_pthread_mutex_destroy","_pthread_create","_pthread_join","_pthread_once","_dispatch_once",
        "_dispatch_async","_dispatch_sync","_dispatch_release","_dispatch_retain","_usleep","_sleep",
        "_nanosleep"
    ]

    public static func family(for symbol: String) -> RE4MachO32ImportFamily {
        if cRuntime.contains(symbol) || symbol.hasPrefix("___stack_chk_") ||
            symbol == "___error" || symbol == "___stderrp" || symbol == "___stdoutp" {
            return .cRuntime
        }
        if symbol.hasPrefix("_objc_") || symbol == "_sel_registerName" || symbol == "_sel_getName" ||
            symbol.hasPrefix("_OBJC_CLASS_$_") || symbol.hasPrefix("_OBJC_METACLASS_$_") ||
            symbol.hasPrefix("_OBJC_IVAR_$_") || symbol.hasPrefix("_OBJC_EHTYPE_$_") ||
            symbol == "_class_getName" || symbol == "_class_getSuperclass" || symbol == "_object_getClass" {
            return .objectiveCRuntime
        }
        if symbol.hasPrefix("__cxa_") || symbol.hasPrefix("___gxx_") ||
            symbol.hasPrefix("_ZTI") || symbol.hasPrefix("_ZTS") || symbol.hasPrefix("_ZTV") ||
            symbol.hasPrefix("_ZN") || symbol.hasPrefix("__ZN") || symbol.hasPrefix("_ZTh") ||
            symbol.hasPrefix("_ZTv") {
            return .cxxRuntime
        }
        if symbol.hasPrefix("_CF") || symbol.hasPrefix("_CG") || symbol.hasPrefix("_CA") ||
            symbol.hasPrefix("_UI") || symbol.hasPrefix("_NS") || symbol.hasPrefix("_AV") ||
            symbol.hasPrefix("_Audio") || symbol.hasPrefix("_CM") || symbol.hasPrefix("_CV") ||
            symbol.hasPrefix("_GL") || symbol.hasPrefix("_gl") || symbol.hasPrefix("_EAGL") ||
            symbol.hasPrefix("_MP") || symbol.hasPrefix("_AB") || symbol.hasPrefix("_CL") ||
            symbol.hasPrefix("_SK") || symbol.hasPrefix("_SC") || symbol.hasPrefix("_Sec") ||
            symbol.hasPrefix("_kCF") || symbol.hasPrefix("_kCG") {
            return .appleFrameworks
        }
        if symbol.hasPrefix("_ERP_") || symbol.hasPrefix("_MCE") ||
            symbol.hasPrefix("_Bio4_") || symbol.hasPrefix("_BIO4_") || symbol.hasPrefix("_RE4_") {
            return .gameOrEngine
        }
        return .unclassified
    }

    private static func kind(_ site: RE4MachO32IndirectImport) -> RE4MachO32ImportSiteKind {
        switch site.sectionType {
        case 6: return .nonLazyPointer
        case 7: return .lazyPointer
        case 8: return .symbolStub
        default: return .otherIndirect
        }
    }

    public static func makePlan(_ image: RE4MachO32Image,
                                guestMemorySize: Int) throws -> RE4MachO32ImportBindingPlan {
        _ = try image.makeLoadPlan(guestMemorySize: guestMemorySize)
        var grouped: [String: [RE4MachO32ImportBindingSite]] = [:]
        var kinds: [RE4MachO32ImportSiteKind: Int] = [:]
        var outOfSegment: [RE4MachO32ImportBindingSite] = []

        for source in image.indirectImports {
            let fam = family(for: source.symbolName)
            let siteKind = kind(source)
            let site = RE4MachO32ImportBindingSite(
                symbolName: source.symbolName, family: fam, sectionName: source.sectionName,
                sectionType: source.sectionType, siteAddress: source.slotAddress,
                entrySize: source.entrySize, kind: siteKind
            )
            grouped[source.symbolName, default: []].append(site)
            kinds[siteKind, default: 0] += 1
            let width = UInt64(max(source.entrySize, 1))
            let end = UInt64(source.slotAddress) + width
            let contained = image.segments.contains {
                UInt64(source.slotAddress) >= UInt64($0.vmAddress) &&
                end <= UInt64($0.vmAddress) + UInt64($0.vmSize)
            }
            if !contained { outOfSegment.append(site) }
        }

        let symbols = grouped.keys.sorted().map { name -> RE4MachO32ImportSymbolPlan in
            let sites = (grouped[name] ?? []).sorted {
                $0.siteAddress == $1.siteAddress ? $0.sectionName < $1.sectionName : $0.siteAddress < $1.siteAddress
            }
            return RE4MachO32ImportSymbolPlan(name: name, family: family(for: name), sites: sites)
        }
        var familyCounts: [RE4MachO32ImportFamily: Int] = [:]
        for symbol in symbols { familyCounts[symbol.family, default: 0] += 1 }

        return RE4MachO32ImportBindingPlan(
            architectureName: image.architectureName, siteCount: image.indirectImports.count,
            symbolPlans: symbols, siteKindCounts: kinds, familySymbolCounts: familyCounts,
            outOfSegmentSites: outOfSegment, hasLegacyIndirectTable: !image.indirectImports.isEmpty,
            dyldBindRecordCount: image.bindRecords.count
        )
    }

    public static func runSyntheticSelfTest() throws -> String {
        let fixture = try RE4MachO32Parser.makeSyntheticSelfTestFixture()
        let image = try RE4MachO32Parser.parse(fixture)
        let plan = try makePlan(image, guestMemorySize: 0x6000)
        guard plan.siteCount == 1, plan.symbolPlans.count == 1,
              plan.symbolPlans[0].name == "_malloc", plan.symbolPlans[0].family == .cRuntime else {
            throw RE4MachO32ImportPlannerTestError.failed("_malloc symbol/family")
        }
        let site = plan.symbolPlans[0].sites.first
        guard site?.siteAddress == 0x3000, site?.kind == .lazyPointer,
              site?.sectionType == 7, site?.entrySize == 4, plan.outOfSegmentSites.isEmpty else {
            throw RE4MachO32ImportPlannerTestError.failed("lazy-pointer slot and segment boundary")
        }
        guard plan.dyldBindRecordCount == 1 else {
            throw RE4MachO32ImportPlannerTestError.failed("synthetic fixture should preserve its independent dyld bind record")
        }
        return "Mach-O import binding plan self-test PASS\n_malloc classified as C runtime (inventory only).\nLazy-pointer slot 0x00003000 validated in __DATA.\nLegacy indirect table site and separate dyld bind record both retained.\nNo pointer was patched and no import was executed."
    }
}
private enum RE4MachO32ImportPlannerTestError: Error { case failed(String) }
