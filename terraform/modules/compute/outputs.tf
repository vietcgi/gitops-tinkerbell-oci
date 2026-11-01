output "instance_id" {
  description = "Instance OCID"
  value       = oci_core_instance.control_plane.id
}

output "public_ip" {
  description = "Reserved (static) public IP address"
  value       = oci_core_public_ip.control_plane.ip_address
}

output "reserved_public_ip_id" {
  description = "OCID of the reserved public IP (for terraform import / OCI console)"
  value       = oci_core_public_ip.control_plane.id
}

output "private_ip" {
  description = "Private IP address"
  value       = oci_core_instance.control_plane.private_ip
}

output "availability_domain" {
  description = "Availability domain"
  value       = oci_core_instance.control_plane.availability_domain
}

output "shape" {
  description = "Instance shape"
  value       = oci_core_instance.control_plane.shape
}
