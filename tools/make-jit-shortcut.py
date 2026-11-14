#!/usr/bin/env python3
"""Builds the "iSH+ JIT" shortcut (app/JIT/iSH+ JIT.shortcut), which lets
iSH+ connect LocalDevVPN to enable JIT and then give the user's own VPN
(e.g. Tailscale) back, like Madeira's JIT shortcut, whose logic it follows.

iSH+ runs it with shortcuts://x-callback-url/run-shortcut and a text input:
  "start [cellular]"  remembers the current VPN (Store Content, iOS 27), turns
                      cellular data off if asked (LocalDevVPN's loopback does
                      not work over cellular), connects LocalDevVPN, and
                      outputs the VPN that was on (empty if none)
  "done [cellular] vpn-off|vpn-restore"
                      after JIT: cellular data back on if asked, then either
                      disconnects LocalDevVPN or reconnects the remembered VPN

iOS 26 has no Store Content: its version (app/JIT-iOS26/iSH+ JIT.shortcut,
same name, which iSH+ runs it by) connects LocalDevVPN for JIT and
disconnects it after, without giving another VPN back ("start" outputs
nothing, so iSH+ asks for "done vpn-off").

Signed with macOS's `shortcuts sign` (mode anyone), so iSH+ can bundle it
and offer it to Shortcuts from the share sheet.
"""
import os
import plistlib
import subprocess
import sys
import tempfile
import uuid

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "app", "JIT", "iSH+ JIT.shortcut")
OUT_IOS26 = os.path.join(ROOT, "app", "JIT-iOS26", "iSH+ JIT.shortcut")

LOCALDEVVPN = {
    "TeamIdentifier": "42Q7QX86GV",
    "BundleIdentifier": "com.jkcoxson.LocalDevVPN",
    "Name": "LocalDevVPN",
    "AppIntentIdentifier": "ControlLocalDevVPNIntent",
}


def new_id():
    return str(uuid.uuid4()).upper()


def action(identifier, **parameters):
    return {"WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": parameters}


def output_of(action_uuid, name):
    return {"Value": {"OutputUUID": action_uuid, "Type": "ActionOutput", "OutputName": name},
            "WFSerializationType": "WFTextTokenAttachment"}


def text_with(action_uuid, name):
    return {"Value": {"string": "￼", "attachmentsByRange": {"{0, 1}": {
        "OutputUUID": action_uuid, "Type": "ActionOutput", "OutputName": name}}},
        "WFSerializationType": "WFTextTokenString"}


def build(remember=True):
    """remember: keeps the VPN that was on and reconnects it (iOS 27)"""
    actions = []
    text = new_id()
    # The input, as text
    actions.append(action("is.workflow.actions.gettext", UUID=text, WFTextActionText={
        "Value": {"string": "￼", "attachmentsByRange": {"{0, 1}": {"Type": "ExtensionInput"}}},
        "WFSerializationType": "WFTextTokenString"}))
    input_text = {"Type": "Variable", "Variable": output_of(text, "Text")}

    def if_contains(word):
        group = new_id()
        start = action("is.workflow.actions.conditional", WFInput=input_text, WFControlFlowMode=0,
                       WFConditionalActionString=word, GroupingIdentifier=group, WFCondition=99)
        end = action("is.workflow.actions.conditional", WFControlFlowMode=2, GroupingIdentifier=group, UUID=new_id())
        return group, start, end

    # If "start"
    start_group, start_if, start_end = if_contains("start")
    actions.append(start_if)
    current = new_id()
    if remember:
        actions.append(action("is.workflow.actions.vpn.get", UUID=current))
        actions.append(action("is.workflow.actions.setstoredcontent", WFInput=text_with(current, "Current VPN"),
                              WFStoredContentKey="previous VPN"))
    _, cell_if, cell_end = if_contains("cellular")
    actions += [cell_if, action("is.workflow.actions.cellulardata.set", OnValue=0), cell_end]
    actions.append(action("com.jkcoxson.LocalDevVPN.ControlLocalDevVPNIntent",
                          AppIntentDescriptor=LOCALDEVVPN, UUID=new_id()))
    if remember:
        actions.append(action("is.workflow.actions.output", WFOutput=text_with(current, "Current VPN"), UUID=new_id()))
    # Otherwise ("done")
    actions.append(action("is.workflow.actions.conditional", GroupingIdentifier=start_group, WFControlFlowMode=1))
    _, cell_if, cell_end = if_contains("cellular")
    actions += [cell_if, action("is.workflow.actions.cellulardata.set"), cell_end]
    _, off_if, off_end = if_contains("vpn-off")
    actions += [off_if, action("com.jkcoxson.LocalDevVPN.ControlLocalDevVPNIntent",
                               AppIntentDescriptor=LOCALDEVVPN, operation="disable", UUID=new_id()), off_end]
    if remember:
        _, restore_if, restore_end = if_contains("vpn-restore")
        stored = new_id()
        actions += [restore_if,
                    # LocalDevVPN off first, then a moment: connecting the
                    # previous VPN while it was still up failed ("configuration
                    # disabled", NEVPNErrorDomain 2)
                    action("com.jkcoxson.LocalDevVPN.ControlLocalDevVPNIntent",
                           AppIntentDescriptor=LOCALDEVVPN, operation="disable", UUID=new_id()),
                    action("is.workflow.actions.delay", WFDelayTime=1),
                    action("is.workflow.actions.getstoredcontent", WFStoredContentKey="previous VPN", UUID=stored),
                    # The stored VPN goes to Set VPN directly: as text, it could not be converted
                    action("is.workflow.actions.vpn.set", WFVPN=output_of(stored, "previous VPN"),
                           WFVPNOperation="Connect", UUID=new_id()),
                    restore_end]
    actions.append(start_end)

    return {
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowClientVersion": "5037.109",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 946986751, "WFWorkflowIconGlyphNumber": 59764},
        "WFWorkflowOutputContentItemClasses": ["WFVPNContentItem"],
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
        "WFWorkflowTypes": [],
        "WFQuickActionSurfaces": [],
        "WFWorkflowImportQuestions": [],
        "WFWorkflowHasShortcutInputVariables": True,
        "WFWorkflowActions": actions,
    }


def main():
    for out, remember in ((OUT, True), (OUT_IOS26, False)):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with tempfile.TemporaryDirectory() as tmp:
            unsigned = os.path.join(tmp, "iSH+ JIT.shortcut")
            with open(unsigned, "wb") as f:
                plistlib.dump(build(remember), f, fmt=plistlib.FMT_BINARY)
            subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", unsigned, "--output", out], check=True)
        print(out)


if __name__ == "__main__":
    sys.exit(main())
