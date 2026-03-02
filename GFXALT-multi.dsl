/*
 * GFXALT-multi SSDT for Apple T2 Macs
 * Minimal _PR3/_DSM injection for GFX0 device
 * Covers common paths: PEG0/EGP0/EGP1, PEGP, RP05.PEGP, RP21.PEGP
 * Version 0x00000002
 */
DefinitionBlock ("", "SSDT", 2, "LH", "GFXALT", 0x00000002)
{
    External (_SB_.PCI0.PEG0.EGP0.EGP1.GFX0, DeviceObj)
    External (_SB_.PCI0.PEG0.PEGP.GFX0,      DeviceObj)
    External (_SB_.PCI0.RP05.PEGP.GFX0,      DeviceObj)
    External (_SB_.PCI0.RP21.PEGP.GFX0,      DeviceObj)

    If (CondRefOf (\_SB.PCI0.PEG0.EGP0.EGP1.GFX0)) {
        Scope (\_SB.PCI0.PEG0.EGP0.EGP1.GFX0) {
            Method (_PR3, 0, NotSerialized) { Return (Package (0) {}) }
            Method (_DSM, 4, NotSerialized) {
                If ((Arg2 == Zero)) { Return (Buffer (One) { 0x03 }) }
                Return (Package (0) {})
            }
        }
    }

    If (CondRefOf (\_SB.PCI0.PEG0.PEGP.GFX0)) {
        Scope (\_SB.PCI0.PEG0.PEGP.GFX0) {
            Method (_PR3, 0, NotSerialized) { Return (Package (0) {}) }
            Method (_DSM, 4, NotSerialized) {
                If ((Arg2 == Zero)) { Return (Buffer (One) { 0x03 }) }
                Return (Package (0) {})
            }
        }
    }

    If (CondRefOf (\_SB.PCI0.RP05.PEGP.GFX0)) {
        Scope (\_SB.PCI0.RP05.PEGP.GFX0) {
            Method (_PR3, 0, NotSerialized) { Return (Package (0) {}) }
            Method (_DSM, 4, NotSerialized) {
                If ((Arg2 == Zero)) { Return (Buffer (One) { 0x03 }) }
                Return (Package (0) {})
            }
        }
    }

    If (CondRefOf (\_SB.PCI0.RP21.PEGP.GFX0)) {
        Scope (\_SB.PCI0.RP21.PEGP.GFX0) {
            Method (_PR3, 0, NotSerialized) { Return (Package (0) {}) }
            Method (_DSM, 4, NotSerialized) {
                If ((Arg2 == Zero)) { Return (Buffer (One) { 0x03 }) }
                Return (Package (0) {})
            }
        }
    }
}

