//
//  ContactResources.swift
//  Monal
//
//  Created by Friedrich Altheide on 24.12.21.
//  Copyright © 2021 Monal.im. All rights reserved.
//
import monalxmpp

import SwiftUI
import OrderedCollections

@ViewBuilder
func resourceRowElement(_ k: String, _ v: some View, space: CGFloat = 5) -> some View {
    HStack {
        Text(k).font(.headline)
        Spacer()
        v.foregroundColor(.secondary)
    }
}

struct ContactResources: View {
    @StateObject var contact: ObservableKVOWrapper<MLContact>
    @State var contactVersionInfos: [String:ObservableKVOWrapper<MLContactSoftwareVersionInfo>]
    @State private var showCaps: String?

    init(contact: ObservableKVOWrapper<MLContact>, previewMock: [String:ObservableKVOWrapper<MLContactSoftwareVersionInfo>]? = nil) {
        _contact = StateObject(wrappedValue: contact)
        
        if previewMock != nil {
            self.contactVersionInfos = previewMock!
        } else {
            var tmpInfos:[String:ObservableKVOWrapper<MLContactSoftwareVersionInfo>] = [:]
            for ressourceName in DataLayer.sharedInstance().resources(for: contact.obj) {
                // load already known software version info from database
                if let softwareInfo = DataLayer.sharedInstance().getSoftwareVersionInfo(forContact: contact.obj.contactJid, resource: ressourceName, andAccount: contact.obj.accountId) {
                    tmpInfos[ressourceName] = ObservableKVOWrapper<MLContactSoftwareVersionInfo>(softwareInfo)
                }
            }
            self.contactVersionInfos = tmpInfos
        }
    }

    var body: some View {
        List {
            ForEach(self.contactVersionInfos.sorted(by:{ $0.0 < $1.0 }), id: \.key) { key, value in
                if let versionInfo = value {
                    Section {
                        VStack {
                            resourceRowElement("Resource:", Text(versionInfo.resource as String))
                            resourceRowElement("Client Name:", Text(versionInfo.appName as String? ?? ""))
                            resourceRowElement("Client Version:", Text(versionInfo.appVersion as String? ?? ""))
                            resourceRowElement("OS:", Text(versionInfo.platformOs as String? ?? ""))
                            if let lastInteraction = versionInfo.lastInteraction as Date? {
                                resourceRowElement("Last Interaction:", HStack {
                                    Text(lastInteraction, style:.date)
                                    Text(lastInteraction, style:.time)
                                })
                            } else {
                                resourceRowElement("Last Interaction:", Text("unsupported"))
                            }
                        }
                        .onTapGesture(count: 2, perform: {
                            showCaps = versionInfo.resource
                        })
                    }
                }
            }
        }
        .richAlert(isPresented:$showCaps, title:Text("XMPP Capabilities")) { resource in
            VStack(alignment: .leading) {
                Text("The resource '\(resource)' has the following capabilities:")
                    .font(Font.body.weight(.semibold))
                Spacer()
                    .frame(height: 20)
                Section {
                    let capsVer = DataLayer.sharedInstance().getVerForUser(self.contact.contactJid, andResource:resource, onAccountNo:self.contact.accountId)
                    let caps = Array(DataLayer.sharedInstance().getCapsforVer(capsVer) as! Set<String>)
                    VStack(alignment: .leading) {
                        ForEach(caps, id: \.self) { cap in
                            Text(cap)
                                .font(.system(.footnote, design:.monospaced))
                            if cap != caps.last {
                                Divider()
                            }
                        }
                    }
                }
            }.foregroundColor(.black)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("kMonalXmppUserSoftWareVersionRefresh")).receive(on: RunLoop.main)) { notification in
            if let xmppAccount = notification.object as? xmpp, let softwareInfo = notification.userInfo?["versionInfo"] as? MLContactSoftwareVersionInfo {
                DDLogVerbose("Got software version info from account \(xmppAccount)...")
                if softwareInfo.fromJid == contact.obj.contactJid && xmppAccount.accountNo == contact.obj.accountId {
                    DispatchQueue.main.async {
                        DDLogVerbose("Successfully matched software version info update to current contact: \(contact.obj)")
                        self.contactVersionInfos[softwareInfo.resource] = ObservableKVOWrapper<MLContactSoftwareVersionInfo>(softwareInfo)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("kMonalLastInteractionUpdatedNotice")).receive(on: RunLoop.main)) { notification in
            DDLogVerbose("Checking lastInteraction update...")
            if let xmppAccount = notification.object as? xmpp {
                DDLogVerbose("Checking lastInteraction update: step 1")
                if let jid = notification.userInfo?["jid"] as? String {
                    DDLogVerbose("Checking lastInteraction update: step 2")
                    if let resource = notification.userInfo?["resource"] as? String {
                        DDLogVerbose("Checking lastInteraction update: step 3")
                        if let lastInteraction = notification.userInfo?["lastInteraction"] as? NSDate {
                DDLogVerbose("Got lastInteraction update from account \(xmppAccount)...")
                if jid == contact.obj.contactJid && xmppAccount.accountNo == contact.obj.accountId {
                    DispatchQueue.main.async {
                        DDLogVerbose("Successfully matched lastInteraction update to current contact: \(contact.obj)")
                        self.contactVersionInfos[resource]?.obj.lastInteraction = lastInteraction as Date
                    }
                }
            } } } }
        }
        .onAppear {
            DDLogVerbose("View will appear...")
            let newTimeout = DispatchTime.now() + 1.0;
            DispatchQueue.main.asyncAfter(deadline: newTimeout) {
                DDLogVerbose("Refreshing software version info...")
                for ressourceName in DataLayer.sharedInstance().resources(for: contact.obj) {
                    // query software version from contact
                    MLXMPPManager.sharedInstance()
                        .getEntitySoftWareVersion(for: contact.obj, andResource: ressourceName)
                }
            }
        }
        .navigationBarTitle("Devices of \(contact.contactDisplayName as String)", displayMode: .inline)
    }
}

func previewMock() -> [String:ObservableKVOWrapper<MLContactSoftwareVersionInfo>] {
    var previewMock:[String:ObservableKVOWrapper<MLContactSoftwareVersionInfo>] = [:]
    previewMock["m1"] = ObservableKVOWrapper<MLContactSoftwareVersionInfo>(MLContactSoftwareVersionInfo.init(jid: "test1@monal.im", andRessource: "m1", andAppName: "Monal", andAppVersion: "1.1.1", andPlatformOS: "ios", andLastInteraction: Date()))
    previewMock["m2"] = ObservableKVOWrapper<MLContactSoftwareVersionInfo>(MLContactSoftwareVersionInfo.init(jid: "test1@monal.im", andRessource: "m2", andAppName: "Monal", andAppVersion: "1.1.2", andPlatformOS: "macOS", andLastInteraction: Date()))
    previewMock["m3"] = ObservableKVOWrapper<MLContactSoftwareVersionInfo>(MLContactSoftwareVersionInfo.init(jid: "test1@monal.im", andRessource: "m3", andAppName: "Monal", andAppVersion: "1.1.2", andPlatformOS: "macOS", andLastInteraction: Date()))
    return previewMock
}

struct ContactResources_Previews: PreviewProvider {
    static var previews: some View {
        ContactResources(contact:ObservableKVOWrapper<MLContact>(MLContact.makeDummyContact(0)), previewMock:previewMock())
    }
}
