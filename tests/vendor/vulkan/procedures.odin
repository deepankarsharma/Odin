package tests_vendor_vulkan

import "core:testing"
import vk "vendor:vulkan"

get_instance_proc_addr_returning_nil :: proc "system" (
	instance: vk.Instance,
	p_name:   cstring,
) -> vk.ProcVoidFunction {
	return nil
}

get_device_proc_addr_returning_nil :: proc "system" (
	device: vk.Device,
	p_name: cstring,
) -> vk.ProcVoidFunction {
	return nil
}

@(test)
load_global_procedures_preserves_bootstrap_pointer :: proc(t: ^testing.T) {
	create_instance := vk.CreateInstance
	debug_utils_messenger_callback_ext := vk.DebugUtilsMessengerCallbackEXT
	device_memory_report_callback_ext := vk.DeviceMemoryReportCallbackEXT
	enumerate_instance_extension_properties := vk.EnumerateInstanceExtensionProperties
	enumerate_instance_layer_properties := vk.EnumerateInstanceLayerProperties
	enumerate_instance_version := vk.EnumerateInstanceVersion
	get_instance_proc_addr := vk.GetInstanceProcAddr
	defer {
		vk.CreateInstance = create_instance
		vk.DebugUtilsMessengerCallbackEXT = debug_utils_messenger_callback_ext
		vk.DeviceMemoryReportCallbackEXT = device_memory_report_callback_ext
		vk.EnumerateInstanceExtensionProperties = enumerate_instance_extension_properties
		vk.EnumerateInstanceLayerProperties = enumerate_instance_layer_properties
		vk.EnumerateInstanceVersion = enumerate_instance_version
		vk.GetInstanceProcAddr = get_instance_proc_addr
	}

	vk.load_proc_addresses_global(rawptr(get_instance_proc_addr_returning_nil))

	testing.expect(
		t,
		rawptr(vk.GetInstanceProcAddr) == rawptr(get_instance_proc_addr_returning_nil),
	)
}

@(test)
load_device_vtable_copies_bootstrap_pointer :: proc(t: ^testing.T) {
	get_device_proc_addr := vk.GetDeviceProcAddr
	defer vk.GetDeviceProcAddr = get_device_proc_addr

	vk.GetDeviceProcAddr = get_device_proc_addr_returning_nil
	vtable: vk.Device_VTable
	vk.load_proc_addresses_device_vtable(nil, &vtable)

	testing.expect(
		t,
		rawptr(vtable.GetDeviceProcAddr) == rawptr(get_device_proc_addr_returning_nil),
	)
}
