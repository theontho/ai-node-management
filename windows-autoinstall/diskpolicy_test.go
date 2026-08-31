package main

import (
	"strings"
	"testing"
)

const gib = uint64(1024 * 1024 * 1024)

func TestChooseTargetPrefersNVMeOverMMC(t *testing.T) {
	candidates := []disk{
		{index: 0, sizeBytes: 119 * gib, busType: busTypeMMC},
		{index: 1, sizeBytes: 119 * gib, busType: busTypeNVMe},
	}
	target, largeEnough := chooseTarget(candidates, 64_000_000_000)
	if target.index != 1 || !largeEnough {
		t.Fatalf("selected %+v, largeEnough=%t; want NVMe disk 1", target, largeEnough)
	}
}

func TestChooseTargetRequiresCapacityBeforePerformance(t *testing.T) {
	candidates := []disk{
		{index: 0, sizeBytes: 32 * gib, busType: busTypeNVMe},
		{index: 1, sizeBytes: 119 * gib, busType: busTypeMMC},
	}
	target, largeEnough := chooseTarget(candidates, 64_000_000_000)
	if target.index != 1 || !largeEnough {
		t.Fatalf("selected %+v, largeEnough=%t; want sufficiently large MMC disk 1", target, largeEnough)
	}
}

func TestChooseTargetFallsBackToLargestAvailableDisk(t *testing.T) {
	candidates := []disk{
		{index: 0, sizeBytes: 48 * gib, busType: busTypeMMC},
		{index: 1, sizeBytes: 32 * gib, busType: busTypeNVMe},
	}
	target, largeEnough := chooseTarget(candidates, 60_000_000_000)
	if target.index != 0 || largeEnough {
		t.Fatalf("selected %+v, largeEnough=%t; want larger fallback disk 0", target, largeEnough)
	}
}

func TestInternalDiskFiltering(t *testing.T) {
	excluded := map[int]bool{4: true}
	tests := []struct {
		disk disk
		want bool
	}{
		{disk{index: 0, busType: busTypeNVMe}, true},
		{disk{index: 1, busType: busTypeMMC}, true},
		{disk{index: 2, busType: busTypeUSB}, false},
		{disk{index: 3, busType: busTypeSD}, false},
		{disk{index: 4, busType: busTypeNVMe}, false},
		{disk{index: 5, busType: busTypeSATA, removable: true}, false},
		{disk{index: 6, sizeBytes: 64 * gib, busType: busTypeSD}, true},
		{disk{index: 7, sizeBytes: 16 * gib, busType: busTypeSD}, false},
	}
	for _, test := range tests {
		if got := isInternalDisk(test.disk, excluded); got != test.want {
			t.Errorf("isInternalDisk(%+v)=%t, want %t", test.disk, got, test.want)
		}
	}
}

func TestRenderAnswer(t *testing.T) {
	rendered, err := renderAnswer("<DiskID>__TARGET_DISK_ID__</DiskID><DiskID>__TARGET_DISK_ID__</DiskID>", 7)
	if err != nil {
		t.Fatal(err)
	}
	if rendered != "<DiskID>7</DiskID><DiskID>7</DiskID>" {
		t.Fatalf("unexpected answer: %s", rendered)
	}
}

func TestWipePlanExcludesTarget(t *testing.T) {
	plan := renderSecondaryWipePlan([]disk{{index: 0}, {index: 1}, {index: 2}}, 1)
	if strings.Contains(plan, "select disk 1") {
		t.Fatalf("wipe plan includes target disk:\n%s", plan)
	}
	for _, expected := range []string{"select disk 0", "select disk 2", "clean"} {
		if !strings.Contains(plan, expected) {
			t.Fatalf("wipe plan is missing %q:\n%s", expected, plan)
		}
	}
}
