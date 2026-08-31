package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"os"
	"runtime"
	"syscall"
	"unsafe"
)

const (
	fileShareRead                   = 0x00000001
	fileShareWrite                  = 0x00000002
	openExisting                    = 3
	ioctlStorageQueryProperty       = 0x002D1400
	ioctlDiskGetDriveGeometryEx     = 0x000700A0
	ioctlVolumeGetVolumeDiskExtents = 0x00560000
	storageDeviceProperty           = 0
	propertyStandardQuery           = 0
)

var (
	kernel32        = syscall.NewLazyDLL("kernel32.dll")
	createFileW     = kernel32.NewProc("CreateFileW")
	deviceIoControl = kernel32.NewProc("DeviceIoControl")
	closeHandle     = kernel32.NewProc("CloseHandle")
)

func openPath(path string) (syscall.Handle, error) {
	utf16Path, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return syscall.InvalidHandle, err
	}
	handle, _, callErr := createFileW.Call(
		uintptr(unsafe.Pointer(utf16Path)),
		0,
		fileShareRead|fileShareWrite,
		0,
		openExisting,
		0,
		0,
	)
	runtime.KeepAlive(utf16Path)
	if handle == uintptr(syscall.InvalidHandle) {
		return syscall.InvalidHandle, callErr
	}
	return syscall.Handle(handle), nil
}

func ioctl(handle syscall.Handle, code uint32, input, output []byte) (uint32, error) {
	var inputPointer uintptr
	if len(input) > 0 {
		inputPointer = uintptr(unsafe.Pointer(&input[0]))
	}
	var outputPointer uintptr
	if len(output) > 0 {
		outputPointer = uintptr(unsafe.Pointer(&output[0]))
	}
	var returned uint32
	result, _, callErr := deviceIoControl.Call(
		uintptr(handle),
		uintptr(code),
		inputPointer,
		uintptr(len(input)),
		outputPointer,
		uintptr(len(output)),
		uintptr(unsafe.Pointer(&returned)),
		0,
	)
	runtime.KeepAlive(input)
	runtime.KeepAlive(output)
	if result == 0 {
		return returned, callErr
	}
	return returned, nil
}

func inspectDisk(index int) (disk, bool, error) {
	handle, err := openPath(fmt.Sprintf(`\\.\PhysicalDrive%d`, index))
	if err != nil {
		if err == syscall.ERROR_FILE_NOT_FOUND || err == syscall.ERROR_PATH_NOT_FOUND {
			return disk{}, false, nil
		}
		return disk{}, false, err
	}
	defer closeHandle.Call(uintptr(handle))

	query := make([]byte, 12)
	binary.LittleEndian.PutUint32(query[0:4], storageDeviceProperty)
	binary.LittleEndian.PutUint32(query[4:8], propertyStandardQuery)
	descriptor := make([]byte, 1024)
	descriptorBytes, err := ioctl(handle, ioctlStorageQueryProperty, query, descriptor)
	if err != nil {
		return disk{}, true, fmt.Errorf("query storage descriptor: %w", err)
	}
	if descriptorBytes < 32 {
		return disk{}, true, fmt.Errorf("storage descriptor is too short: %d bytes", descriptorBytes)
	}

	geometry := make([]byte, 256)
	geometryBytes, err := ioctl(handle, ioctlDiskGetDriveGeometryEx, nil, geometry)
	if err != nil {
		return disk{}, true, fmt.Errorf("query disk geometry: %w", err)
	}
	if geometryBytes < 32 {
		return disk{}, true, fmt.Errorf("disk geometry is too short: %d bytes", geometryBytes)
	}

	return disk{
		index:     index,
		sizeBytes: binary.LittleEndian.Uint64(geometry[24:32]),
		busType:   binary.LittleEndian.Uint32(descriptor[28:32]),
		removable: descriptor[10] != 0,
	}, true, nil
}

func volumeDiskIndices(volume string) (map[int]bool, error) {
	handle, err := openPath(`\\.\` + volume)
	if err != nil {
		return nil, fmt.Errorf("open installer volume %s: %w", volume, err)
	}
	defer closeHandle.Call(uintptr(handle))

	extents := make([]byte, 4096)
	extentBytes, err := ioctl(handle, ioctlVolumeGetVolumeDiskExtents, nil, extents)
	if err != nil {
		return nil, fmt.Errorf("map installer volume %s to its disk: %w", volume, err)
	}
	if extentBytes < 32 {
		return nil, fmt.Errorf("installer volume extent data is too short: %d bytes", extentBytes)
	}
	count := binary.LittleEndian.Uint32(extents[0:4])
	if count == 0 || count > 64 || uint64(8+count*24) > uint64(extentBytes) {
		return nil, fmt.Errorf("installer volume reported an invalid extent count: %d", count)
	}

	indices := make(map[int]bool, count)
	for i := uint32(0); i < count; i++ {
		offset := 8 + i*24
		indices[int(binary.LittleEndian.Uint32(extents[offset:offset+4]))] = true
	}
	return indices, nil
}

func fallback(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "automatic disk selection unavailable: "+format+"\n", args...)
	fmt.Fprintln(os.Stderr, "continuing with ordinary interactive Windows Setup")
	os.Exit(2)
}

func main() {
	excludeVolume := flag.String("exclude-volume", "", "installer volume such as D:")
	answerTemplate := flag.String("answer-template", "", "unattended answer template")
	answerOutput := flag.String("answer-output", "", "rendered unattended answer path")
	wipePlanOutput := flag.String("wipe-plan-output", "", "DiskPart plan for secondary internal disks")
	preferredMinBytes := flag.Uint64("preferred-min-bytes", 60_000_000_000, "preferred minimum target size")
	flag.Parse()

	if *excludeVolume == "" || *answerTemplate == "" || *answerOutput == "" || *wipePlanOutput == "" {
		fmt.Fprintln(os.Stderr, "disk selector requires the installer volume, answer paths, and wipe-plan path")
		os.Exit(1)
	}

	excluded, err := volumeDiskIndices(*excludeVolume)
	if err != nil {
		fallback("%v", err)
	}
	fmt.Printf("Excluding installer volume %s on disk(s):", *excludeVolume)
	for index := 0; index < 64; index++ {
		if excluded[index] {
			fmt.Printf(" PhysicalDrive%d", index)
		}
	}
	fmt.Println()

	var candidates []disk
	for index := 0; index < 64; index++ {
		candidate, present, inspectErr := inspectDisk(index)
		if inspectErr != nil {
			fmt.Fprintf(os.Stderr, "warning: could not inspect PhysicalDrive%d: %v\n", index, inspectErr)
			continue
		}
		if !present {
			continue
		}
		internal := isInternalDisk(candidate, excluded)
		fmt.Printf(
			"PhysicalDrive%d: size=%d bus=%s removable=%t internal=%t installer=%t\n",
			candidate.index,
			candidate.sizeBytes,
			busName(candidate.busType),
			candidate.removable,
			internal,
			excluded[candidate.index],
		)
		if internal {
			candidates = append(candidates, candidate)
		}
	}
	if len(candidates) == 0 {
		fallback("no usable internal disk was identified")
	}

	target, largeEnough := chooseTarget(candidates, *preferredMinBytes)
	if largeEnough {
		fmt.Printf(
			"Selected PhysicalDrive%d (%s, %d bytes): highest-performance internal disk meeting the preferred size.\n",
			target.index,
			busName(target.busType),
			target.sizeBytes,
		)
	} else {
		fmt.Printf(
			"No internal disk meets %d bytes; selected best available PhysicalDrive%d (%s, %d bytes).\n",
			*preferredMinBytes,
			target.index,
			busName(target.busType),
			target.sizeBytes,
		)
	}

	template, err := os.ReadFile(*answerTemplate)
	if err != nil {
		fallback("read answer template: %v", err)
	}
	answer, err := renderAnswer(string(template), target.index)
	if err != nil {
		fallback("%v", err)
	}
	if err := os.WriteFile(*answerOutput, []byte(answer), 0600); err != nil {
		fallback("write rendered answer file: %v", err)
	}
	if len(candidates) > 1 {
		if err := os.WriteFile(
			*wipePlanOutput,
			[]byte(renderSecondaryWipePlan(candidates, target.index)),
			0600,
		); err != nil {
			fallback("write secondary-disk wipe plan: %v", err)
		}
	} else if err := os.Remove(*wipePlanOutput); err != nil && !os.IsNotExist(err) {
		fallback("remove stale secondary-disk wipe plan: %v", err)
	}
}
