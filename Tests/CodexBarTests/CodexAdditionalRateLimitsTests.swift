import Foundation
import Testing
@testable import CodexBarCore

struct CodexAdditionalRateLimitsTests {
    @Test
    func `maps additional spark limit into a named extra rate window`() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 22,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 43,
              "reset_at": 1767407914,
              "limit_window_seconds": 604800
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "gpt_5_3_codex_spark",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 30,
                  "reset_at": 1766948068,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 12345
                },
                "secondary_window": {
                  "used_percent": 100,
                  "reset_at": 1767407914,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 56789
                }
              }
            }
          ]
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let mapped = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        let snapshot = try #require(mapped)
        // Primary/weekly behavior is unchanged.
        #expect(snapshot.primary?.usedPercent == 22)
        #expect(snapshot.secondary?.usedPercent == 43)
        // Spark surfaces as distinct 5-hour and weekly extra windows.
        let extras = try #require(snapshot.extraRateWindows)
        #expect(extras.count == 2)
        let spark = try #require(extras.first)
        #expect(spark.id == "codex-spark")
        #expect(spark.title == "Codex Spark 5-hour")
        #expect(spark.window.usedPercent == 30)
        #expect(spark.window.windowMinutes == 300)
        #expect(spark.window.resetsAt != nil)
        let weekly = try #require(extras.last)
        #expect(weekly.id == "codex-spark-weekly")
        #expect(weekly.title == "Codex Spark Weekly")
        #expect(weekly.window.usedPercent == 100)
        #expect(weekly.window.windowMinutes == 10080)
        #expect(weekly.window.resetsAt != nil)
    }

    @Test
    func `keeps valid spark window when an additional limit sibling is malformed`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": { "used_percent": 22, "reset_at": 1766948068, "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 43, "reset_at": 1767407914, "limit_window_seconds": 604800 }
          },
          "additional_rate_limits": [
            "garbage-not-an-object",
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "gpt_5_3_codex_spark",
              "rate_limit": {
                "primary_window": { "used_percent": 30, "reset_at": 1766948068, "limit_window_seconds": 18000 }
              }
            },
            42
          ]
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let mapped = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        let snapshot = try #require(mapped)
        // Valid primary/weekly fields do not regress.
        #expect(snapshot.primary?.usedPercent == 22)
        #expect(snapshot.secondary?.usedPercent == 43)
        // The malformed siblings are skipped, but the valid Spark entry survives.
        let extras = try #require(snapshot.extraRateWindows)
        #expect(extras.count == 1)
        #expect(extras.first?.id == "codex-spark")
        #expect(extras.first?.window.usedPercent == 30)
    }

    @Test
    func `keeps primary usage when every additional limit element is malformed`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": { "used_percent": 22, "reset_at": 1766948068, "limit_window_seconds": 18000 }
          },
          "additional_rate_limits": ["garbage", 1, true]
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let snapshot = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        #expect(snapshot?.primary?.usedPercent == 22)
        #expect(snapshot?.extraRateWindows == nil)
    }

    @Test
    func `omits extra rate windows when additional limits are absent`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 22,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            }
          }
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let snapshot = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        #expect(snapshot?.primary?.usedPercent == 22)
        #expect(snapshot?.extraRateWindows == nil)
    }

    @Test
    func `tolerates malformed additional limits while keeping primary window`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 22,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            }
          },
          "additional_rate_limits": "unexpected"
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let snapshot = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        #expect(snapshot?.primary?.usedPercent == 22)
        #expect(snapshot?.extraRateWindows == nil)
    }

    @Test
    func `skips additional limits without a usable window`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 22,
              "reset_at": 1766948068,
              "limit_window_seconds": 18000
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "gpt_5_3_codex_spark",
              "rate_limit": null
            }
          ]
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let snapshot = try CodexOAuthFetchStrategy._mapUsageForTesting(Data(json.utf8), credentials: creds)
        #expect(snapshot?.primary?.usedPercent == 22)
        #expect(snapshot?.extraRateWindows == nil)
    }

    @Test
    func `maps non spark additional limit using a slugged id and api label`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        [
          {
            "limit_name": "GPT-5.3-Codex-Mini",
            "metered_feature": "gpt_5_3_codex_mini",
            "rate_limit": {
              "allowed": true,
              "limit_reached": false,
              "primary_window": {
                "used_percent": 12,
                "reset_at": 1766948068,
                "limit_window_seconds": 18000
              }
            }
          },
          {
            "limit_name": "GPT-5.3-Codex-Mini",
            "metered_feature": "gpt_5_3_codex_mini",
            "rate_limit": {
              "allowed": true,
              "limit_reached": false,
              "primary_window": {
                "used_percent": 99,
                "reset_at": 1766948068,
                "limit_window_seconds": 18000
              }
            }
          }
        ]
        """
        let entries = try JSONDecoder().decode([CodexUsageResponse.AdditionalRateLimit].self, from: Data(json.utf8))
        let windows = CodexAdditionalRateLimitMapper.extraRateWindows(from: entries, now: now)
        // Duplicate ids collapse to the first occurrence.
        #expect(windows.count == 1)
        let window = try #require(windows.first)
        #expect(window.id == "codex-gpt-5-3-codex-mini")
        #expect(window.title == "GPT-5.3-Codex-Mini")
        #expect(window.window.usedPercent == 12)
    }

    @Test
    func `dedupes split spark entries by window kind`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        [
          {
            "limit_name": "GPT-5.3-Codex-Spark",
            "metered_feature": "gpt_5_3_codex_spark",
            "rate_limit": {
              "allowed": true,
              "limit_reached": false,
              "primary_window": {
                "used_percent": 20,
                "reset_at": 1766948068,
                "limit_window_seconds": 18000
              }
            }
          },
          {
            "limit_name": "GPT-5.3-Codex-Spark Weekly",
            "metered_feature": "gpt_5_3_codex_spark",
            "rate_limit": {
              "allowed": true,
              "limit_reached": false,
              "primary_window": {
                "used_percent": 80,
                "reset_at": 1767407914,
                "limit_window_seconds": 604800
              }
            }
          },
          {
            "limit_name": "GPT-5.3-Codex-Spark Duplicate",
            "metered_feature": "gpt_5_3_codex_spark",
            "rate_limit": {
              "allowed": true,
              "limit_reached": false,
              "primary_window": {
                "used_percent": 99,
                "reset_at": 1766948068,
                "limit_window_seconds": 18000
              }
            }
          }
        ]
        """
        let entries = try JSONDecoder().decode([CodexUsageResponse.AdditionalRateLimit].self, from: Data(json.utf8))
        let windows = CodexAdditionalRateLimitMapper.extraRateWindows(from: entries, now: now)

        #expect(windows.map(\.id) == ["codex-spark", "codex-spark-weekly"])
        #expect(windows.first?.window.usedPercent == 20)
        #expect(windows.last?.window.usedPercent == 80)
    }

    @Test
    func `maps generic model with both 5h and weekly windows`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        [
          {
            "limit_name": "GPT-5.3-Codex-Mini",
            "metered_feature": "gpt_5_3_codex_mini",
            "rate_limit": {
              "allowed": true,
              "limit_reached": false,
              "primary_window": {
                "used_percent": 10,
                "reset_at": 1766948068,
                "limit_window_seconds": 18000
              },
              "secondary_window": {
                "used_percent": 100,
                "reset_at": 1767407914,
                "limit_window_seconds": 604800
              }
            }
          }
        ]
        """
        let entries = try JSONDecoder().decode([CodexUsageResponse.AdditionalRateLimit].self, from: Data(json.utf8))
        let windows = CodexAdditionalRateLimitMapper.extraRateWindows(from: entries, now: now)

        #expect(windows.count == 2)
        #expect(windows.map(\.id) == ["codex-gpt-5-3-codex-mini", "codex-gpt-5-3-codex-mini-weekly"])
        #expect(windows[0].title == "GPT-5.3-Codex-Mini 5-hour")
        #expect(windows[0].window.usedPercent == 10)
        #expect(windows[1].title == "GPT-5.3-Codex-Mini Weekly")
        #expect(windows[1].window.usedPercent == 100)
    }

    @Test
    func `maps generic model with 1h and 2h windows without dropping or mislabeling`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        [
          {
            "limit_name": "Custom-Model",
            "metered_feature": "custom_model",
            "rate_limit": {
              "primary_window": {
                "used_percent": 15,
                "reset_at": 1766948068,
                "limit_window_seconds": 3600
              },
              "secondary_window": {
                "used_percent": 45,
                "reset_at": 1766951668,
                "limit_window_seconds": 7200
              }
            }
          }
        ]
        """
        let entries = try JSONDecoder().decode([CodexUsageResponse.AdditionalRateLimit].self, from: Data(json.utf8))
        let windows = CodexAdditionalRateLimitMapper.extraRateWindows(from: entries, now: now)

        #expect(windows.count == 2)
        #expect(windows.map(\.id) == ["codex-custom-model-1h", "codex-custom-model-2h"])
        #expect(windows[0].title == "Custom-Model 1-hour")
        #expect(windows[0].window.usedPercent == 15)
        #expect(windows[1].title == "Custom-Model 2-hour")
        #expect(windows[1].window.usedPercent == 45)
    }

    @Test
    func `maps generic model with 1h and 1day windows with accurate titles`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        [
          {
            "limit_name": "Daily-Model",
            "metered_feature": "daily_model",
            "rate_limit": {
              "primary_window": {
                "used_percent": 25,
                "reset_at": 1766948068,
                "limit_window_seconds": 3600
              },
              "secondary_window": {
                "used_percent": 75,
                "reset_at": 1767030868,
                "limit_window_seconds": 86400
              }
            }
          }
        ]
        """
        let entries = try JSONDecoder().decode([CodexUsageResponse.AdditionalRateLimit].self, from: Data(json.utf8))
        let windows = CodexAdditionalRateLimitMapper.extraRateWindows(from: entries, now: now)

        #expect(windows.count == 2)
        #expect(windows.map(\.id) == ["codex-daily-model-1h", "codex-daily-model-1d"])
        #expect(windows[0].title == "Daily-Model 1-hour")
        #expect(windows[0].window.usedPercent == 25)
        #expect(windows[1].title == "Daily-Model 1-day")
        #expect(windows[1].window.usedPercent == 75)
    }

    @Test
    func `maps generic model with only secondary window`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        [
          {
            "limit_name": "Weekly-Only",
            "metered_feature": "weekly_only",
            "rate_limit": {
              "secondary_window": {
                "used_percent": 50,
                "reset_at": 1767407914,
                "limit_window_seconds": 604800
              }
            }
          }
        ]
        """
        let entries = try JSONDecoder().decode([CodexUsageResponse.AdditionalRateLimit].self, from: Data(json.utf8))
        let windows = CodexAdditionalRateLimitMapper.extraRateWindows(from: entries, now: now)

        #expect(windows.count == 1)
        #expect(windows.first?.id == "codex-weekly-only-weekly")
        #expect(windows.first?.title == "Weekly-Only Weekly")
        #expect(windows.first?.window.usedPercent == 50)
    }

    @Test
    func `dedupes split and duplicate generic entries by duration`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        [
          {
            "limit_name": "Split-Model",
            "metered_feature": "split_model",
            "rate_limit": {
              "primary_window": { "used_percent": 10, "reset_at": 1800018000, "limit_window_seconds": 18000 }
            }
          },
          {
            "limit_name": "Split-Model",
            "metered_feature": "split_model",
            "rate_limit": {
              "secondary_window": { "used_percent": 90, "reset_at": 1800604800, "limit_window_seconds": 604800 }
            }
          },
          {
            "limit_name": "Split-Model Duplicate",
            "metered_feature": "split_model",
            "rate_limit": {
              "primary_window": { "used_percent": 99, "reset_at": 1800018000, "limit_window_seconds": 18000 }
            }
          }
        ]
        """
        let entries = try JSONDecoder().decode([CodexUsageResponse.AdditionalRateLimit].self, from: Data(json.utf8))
        let windows = CodexAdditionalRateLimitMapper.extraRateWindows(from: entries, now: now)

        try #require(windows.count == 2)
        #expect(windows.map(\.id) == ["codex-split-model", "codex-split-model-weekly"])
        #expect(windows[0].window.usedPercent == 10)
        #expect(windows[1].window.usedPercent == 90)
    }

    @Test
    func `dedupes split 5h in secondary and weekly`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        [
          {
            "limit_name": "Split-5h",
            "metered_feature": "split_5h",
            "rate_limit": {
              "primary_window": { "used_percent": 10, "reset_at": 1800018000, "limit_window_seconds": 18000 }
            }
          },
          {
            "limit_name": "Split-5h",
            "metered_feature": "split_5h",
            "rate_limit": {
              "secondary_window": { "used_percent": 20, "reset_at": 1800018000, "limit_window_seconds": 18000 }
            }
          },
          {
            "limit_name": "Split-5h",
            "metered_feature": "split_5h",
            "rate_limit": {
              "secondary_window": { "used_percent": 90, "reset_at": 1800604800, "limit_window_seconds": 604800 }
            }
          }
        ]
        """
        let entries = try JSONDecoder().decode([CodexUsageResponse.AdditionalRateLimit].self, from: Data(json.utf8))
        let windows = CodexAdditionalRateLimitMapper.extraRateWindows(from: entries, now: now)

        try #require(windows.count == 2)
        #expect(windows.map(\.id) == ["codex-split-5h", "codex-split-5h-weekly"])
        #expect(windows[0].window.usedPercent == 10)
        #expect(windows[1].window.usedPercent == 90)
    }
}
