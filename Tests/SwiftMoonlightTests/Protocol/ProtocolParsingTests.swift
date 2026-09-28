import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func parsesSunshineServerInfoFixture() throws {
    let data = try fixtureData(named: "serverinfo_sunshine_paired.xml")
    let parser = HostInfoParser()

    let serverInfo = try parser.parseServerInfo(data)

    #expect(serverInfo.pairingState == .paired)
    #expect(serverInfo.appVersion == "Sunshine-2026.319.232111")
    #expect(serverInfo.gfeVersion == "3.28.0.0")
    #expect(serverInfo.rtspSessionURL == "rtsp://192.168.1.10:47998")
    #expect(serverInfo.codecSupportFlags == 589823)
}

@Test
func parsesAppListFixture() throws {
    let data = try fixtureData(named: "applist_sunshine.xml")
    let parser = AppListParser()

    let apps = try parser.parseAppList(data)

    #expect(apps.count == 2)
    #expect(apps[0].id == "desktop")
    #expect(apps[0].name == "Desktop")
    #expect(!apps[0].supportsHDR)
    #expect(apps[1].id == "steam")
    #expect(apps[1].name == "Steam")
    #expect(apps[1].supportsHDR)
}

@Test
func parsesApolloServerInfoFixture() throws {
    let data = try fixtureData(named: "serverinfo_apollo_paired.xml")
    let parser = HostInfoParser()

    let serverInfo = try parser.parseServerInfo(data)

    #expect(serverInfo.pairingState == .paired)
    #expect(serverInfo.appVersion == "Apollo-0.4.6")
    #expect(serverInfo.rtspSessionURL == "rtsp://192.168.1.11:47998")
}

@Test
func parsesLiveStyleServerInfoPairStatusResponse() throws {
    let data = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200"><hostname>apollo-host</hostname><appversion>7.1.431.-1</appversion><GfeVersion>3.23.0.74</GfeVersion><uniqueid>11111111-2222-3333-4444-555555555555</uniqueid><HttpsPort>47984</HttpsPort><ExternalPort>47989</ExternalPort><MaxLumaPixelsHEVC>1869449984</MaxLumaPixelsHEVC><mac>00:00:00:00:00:00</mac><Permission>0</Permission><LocalIP>192.0.2.28</LocalIP><ServerCodecModeSupport>1835777</ServerCodecModeSupport><PairStatus>0</PairStatus><currentgame>0</currentgame><currentgameuuid/><state>SUNSHINE_SERVER_FREE</state></root>
        """.utf8
    )
    let parser = HostInfoParser()

    let serverInfo = try parser.parseServerInfo(data)

    #expect(serverInfo.pairingState == .unpaired)
    #expect(serverInfo.appVersion == "7.1.431.-1")
    #expect(serverInfo.gfeVersion == "3.23.0.74")
    #expect(serverInfo.codecSupportFlags == 1835777)
}
