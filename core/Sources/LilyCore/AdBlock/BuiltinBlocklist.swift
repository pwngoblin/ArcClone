import Foundation

/// The built-in list, used even offline: major ad and tracking networks, YouTube's ad endpoints,
/// and common ad containers.
enum BuiltinBlocklist {
    static let domains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com", "googletagservices.com",
        "google-analytics.com", "googletagmanager.com", "pagead2.googlesyndication.com", "imasdk.googleapis.com",
        "amazon-adsystem.com", "adnxs.com", "adsrvr.org", "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com", "indexww.com", "smartadserver.com",
        "yieldmo.com", "sharethrough.com", "triplelift.com", "teads.tv", "media.net", "33across.com", "moatads.com",
        "scorecardresearch.com", "quantserve.com", "quantcount.com", "chartbeat.com", "chartbeat.net", "hotjar.com",
        "mouseflow.com", "fullstory.com", "crazyegg.com", "mixpanel.com", "segment.io", "segment.com", "amplitude.com",
        "branch.io", "app-measurement.com", "adcolony.com", "applovin.com", "unityads.unity3d.com", "inmobi.com",
        "zedo.com", "revcontent.com", "mgid.com", "propellerads.com", "popads.net", "popcash.net", "adsterra.com",
        "exoclick.com", "juicyads.com", "trafficjunky.net", "bidswitch.net", "contextweb.com", "lijit.com",
        "sovrn.com", "gumgum.com", "spotxchange.com", "springserve.com", "adform.net", "adition.com", "serving-sys.com",
        "flashtalking.com", "sizmek.com", "advertising.com", "adtechus.com", "yieldlab.net", "stickyadstv.com",
        "connect.facebook.net", "ads-twitter.com", "static.ads-twitter.com", "ads.linkedin.com", "px.ads.linkedin.com",
        "analytics.tiktok.com", "ads.tiktok.com", "bat.bing.com", "clarity.ms", "ads.yahoo.com", "analytics.yahoo.com",
        "adroll.com", "perfectaudience.com", "demdex.net", "omtrdc.net", "2o7.net", "everesttech.net", "krxd.net",
        "bluekai.com", "exelator.com", "eyeota.net", "tapad.com", "rlcdn.com", "agkn.com", "adsymptotic.com",
        "nativo.com", "zemanta.com", "adblade.com", "infolinks.com", "buysellads.com", "carbonads.net", "ad.doubleclick.net",
    ]

    static let paths = [
        "youtube.com/api/stats/ads", "youtube.com/pagead/", "youtube.com/ptracking", "youtube.com/get_midroll_",
        "/pagead/adview", "/pagead/conversion", "/ads/ga-audiences",
    ]

    static let selectors = [
        "ins.adsbygoogle", ".adsbygoogle", "[id^='google_ads_iframe']", "[id^='div-gpt-ad']", "iframe[src*='doubleclick.net']",
        "iframe[src*='googlesyndication.com']", ".ad-banner", ".ad-container", ".ad-slot", ".advertisement", "[data-ad-slot]",
        "[aria-label='Advertisement']", ".taboola-feed", "[id^='taboola-']", ".OUTBRAIN", "[data-widget-id^='outbrain']",
    ]

    static var rules: [[String: Any]] {
        var rules: [[String: Any]] = domains.map {
            ["trigger": ["url-filter": "^[^:]+://+([^:/]+\\.)?" + FilterListConverter.regex(for: $0) + "[/:]"], "action": ["type": "block"]]
        }
        rules += paths.map { ["trigger": ["url-filter": FilterListConverter.regex(for: $0)], "action": ["type": "block"]] }
        rules.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")]])
        return rules
    }
}
