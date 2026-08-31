package main

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

const (
	busTypeUnknown           = 0
	busTypeSCSI              = 1
	busTypeATAPI             = 2
	busTypeATA               = 3
	busType1394              = 4
	busTypeSSA               = 5
	busTypeFibre             = 6
	busTypeUSB               = 7
	busTypeRAID              = 8
	busTypeISCSI             = 9
	busTypeSAS               = 10
	busTypeSATA              = 11
	busTypeSD                = 12
	busTypeMMC               = 13
	busTypeVirtual           = 14
	busTypeFileBackedVirtual = 15
	busTypeSpaces            = 16
	busTypeNVMe              = 17
	busTypeSCM               = 18
	busTypeUFS               = 19
	busTypeNVMeOF            = 20
)

type disk struct {
	index     int
	sizeBytes uint64
	busType   uint32
	removable bool
}

func busName(busType uint32) string {
	names := map[uint32]string{
		busTypeUnknown:           "unknown",
		busTypeSCSI:              "SCSI",
		busTypeATAPI:             "ATAPI",
		busTypeATA:               "ATA",
		busType1394:              "IEEE-1394",
		busTypeSSA:               "SSA",
		busTypeFibre:             "Fibre Channel",
		busTypeUSB:               "USB",
		busTypeRAID:              "RAID",
		busTypeISCSI:             "iSCSI",
		busTypeSAS:               "SAS",
		busTypeSATA:              "SATA",
		busTypeSD:                "SD",
		busTypeMMC:               "MMC/eMMC",
		busTypeVirtual:           "virtual",
		busTypeFileBackedVirtual: "file-backed virtual",
		busTypeSpaces:            "Storage Spaces",
		busTypeNVMe:              "NVMe",
		busTypeSCM:               "storage-class memory",
		busTypeUFS:               "UFS",
		busTypeNVMeOF:            "NVMe-oF",
	}
	if name, ok := names[busType]; ok {
		return name
	}
	return fmt.Sprintf("bus-%d", busType)
}

func isInternalDisk(candidate disk, excluded map[int]bool) bool {
	if excluded[candidate.index] {
		return false
	}
	if candidate.removable && candidate.busType != busTypeMMC {
		return false
	}
	if candidate.busType == busTypeSD {
		return !candidate.removable && candidate.sizeBytes >= 32_000_000_000
	}
	switch candidate.busType {
	case busTypeSCSI,
		busTypeATA,
		busTypeSSA,
		busTypeFibre,
		busTypeRAID,
		busTypeISCSI,
		busTypeSAS,
		busTypeSATA,
		busTypeMMC,
		busTypeVirtual,
		busTypeSpaces,
		busTypeNVMe,
		busTypeSCM,
		busTypeUFS,
		busTypeNVMeOF:
		return true
	default:
		return false
	}
}

func performanceScore(busType uint32) int {
	switch busType {
	case busTypeSCM:
		return 700
	case busTypeNVMe, busTypeNVMeOF:
		return 600
	case busTypeUFS:
		return 500
	case busTypeSATA, busTypeSAS, busTypeRAID, busTypeSpaces:
		return 400
	case busTypeATA, busTypeSCSI, busTypeVirtual:
		return 300
	case busTypeSSA, busTypeFibre, busTypeISCSI:
		return 200
	case busTypeMMC:
		return 100
	default:
		return 0
	}
}

func chooseTarget(candidates []disk, preferredMinBytes uint64) (disk, bool) {
	ranked := append([]disk(nil), candidates...)
	sort.Slice(ranked, func(i, j int) bool {
		iLargeEnough := ranked[i].sizeBytes >= preferredMinBytes
		jLargeEnough := ranked[j].sizeBytes >= preferredMinBytes
		if iLargeEnough != jLargeEnough {
			return iLargeEnough
		}
		if !iLargeEnough && ranked[i].sizeBytes != ranked[j].sizeBytes {
			return ranked[i].sizeBytes > ranked[j].sizeBytes
		}
		iScore := performanceScore(ranked[i].busType)
		jScore := performanceScore(ranked[j].busType)
		if iScore != jScore {
			return iScore > jScore
		}
		if ranked[i].sizeBytes != ranked[j].sizeBytes {
			return ranked[i].sizeBytes > ranked[j].sizeBytes
		}
		return ranked[i].index < ranked[j].index
	})
	if len(ranked) == 0 {
		return disk{}, false
	}
	return ranked[0], ranked[0].sizeBytes >= preferredMinBytes
}

func renderAnswer(template string, targetIndex int) (string, error) {
	const placeholder = "__TARGET_DISK_ID__"
	if strings.Count(template, placeholder) != 2 {
		return "", fmt.Errorf("answer template must contain exactly two %s placeholders", placeholder)
	}
	return strings.ReplaceAll(template, placeholder, strconv.Itoa(targetIndex)), nil
}

func renderSecondaryWipePlan(candidates []disk, targetIndex int) string {
	secondary := append([]disk(nil), candidates...)
	sort.Slice(secondary, func(i, j int) bool {
		return secondary[i].index < secondary[j].index
	})

	lines := []string{
		"rem Best-effort removal of partition tables from non-target internal disks.",
	}
	for _, candidate := range secondary {
		if candidate.index == targetIndex {
			continue
		}
		lines = append(
			lines,
			fmt.Sprintf("select disk %d", candidate.index),
			"online disk noerr",
			"attributes disk clear readonly noerr",
			"clean",
		)
	}
	lines = append(lines, "exit", "")
	return strings.Join(lines, "\r\n")
}
