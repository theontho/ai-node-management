package main

import (
	"crypto/rand"
	"fmt"
	"math/big"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var computerNameAdjectives = []string{
	"amber", "azure", "black", "blue", "bold", "brave", "brisk", "calm",
	"coral", "crisp", "dusk", "eager", "fair", "fast", "fleet", "fresh",
	"gold", "grand", "green", "happy", "hazy", "ivory", "jolly", "keen",
	"light", "lucky", "lunar", "merry", "misty", "noble", "north", "prime",
	"proud", "quick", "quiet", "rapid", "ready", "red", "royal", "sage",
	"sharp", "shy", "smart", "solar", "solid", "stark", "still", "swift",
	"vivid", "warm", "wild", "young", "zesty", "aqua", "clear", "cool",
	"deep", "early", "level", "lucid", "neat", "pale", "true", "white",
}

var computerNameNouns = []string{
	"ant", "bear", "bison", "boar", "crane", "crow", "deer", "dingo",
	"dove", "eagle", "finch", "fox", "gecko", "goose", "hawk", "heron",
	"horse", "koala", "lemur", "lion", "lynx", "moose", "mouse", "otter",
	"owl", "panda", "puma", "quail", "raven", "robin", "seal", "shark",
	"sheep", "sloth", "snake", "stork", "swan", "tiger", "toad", "trout",
	"whale", "wolf", "yak", "zebra", "cedar", "cloud", "comet", "delta",
	"ember", "field", "flame", "frost", "grove", "maple", "ocean", "orbit",
	"pine", "river", "stone", "storm", "vault", "wave", "wind", "star",
}

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

func generateComputerName(prefix string) (string, error) {
	if matched, err := regexp.MatchString(`^[A-Za-z][A-Za-z0-9]{0,2}$`, prefix); err != nil || !matched {
		return "", fmt.Errorf("invalid computer-name prefix %q", prefix)
	}

	adjectiveIndex, err := rand.Int(rand.Reader, big.NewInt(int64(len(computerNameAdjectives))))
	if err != nil {
		return "", fmt.Errorf("choose computer-name adjective: %w", err)
	}
	nounIndex, err := rand.Int(rand.Reader, big.NewInt(int64(len(computerNameNouns))))
	if err != nil {
		return "", fmt.Errorf("choose computer-name noun: %w", err)
	}
	return fmt.Sprintf(
		"%s-%s-%s",
		prefix,
		computerNameAdjectives[adjectiveIndex.Int64()],
		computerNameNouns[nounIndex.Int64()],
	), nil
}

func renderAnswer(template string, targetIndex int, computerName string) (string, error) {
	const diskPlaceholder = "__TARGET_DISK_ID__"
	const computerNamePlaceholder = "__RUNTIME_COMPUTER_NAME__"
	if strings.Count(template, diskPlaceholder) != 2 {
		return "", fmt.Errorf(
			"answer template must contain exactly two %s placeholders",
			diskPlaceholder,
		)
	}
	if strings.Count(template, computerNamePlaceholder) != 1 {
		return "", fmt.Errorf(
			"answer template must contain exactly one %s placeholder",
			computerNamePlaceholder,
		)
	}
	rendered := strings.ReplaceAll(template, diskPlaceholder, strconv.Itoa(targetIndex))
	return strings.ReplaceAll(rendered, computerNamePlaceholder, computerName), nil
}

func renderSecondaryDiskPlan(candidates []disk, targetIndex int) string {
	secondary := append([]disk(nil), candidates...)
	sort.Slice(secondary, func(i, j int) bool {
		return secondary[i].index < secondary[j].index
	})

	lines := []string{
		"rem Prepare non-target internal disks as empty NTFS data volumes.",
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
			"convert gpt",
			"create partition primary",
			fmt.Sprintf(`format fs=ntfs quick label="AI_NODE_DATA_%d"`, candidate.index),
		)
	}
	lines = append(lines, "exit", "")
	return strings.Join(lines, "\r\n")
}
