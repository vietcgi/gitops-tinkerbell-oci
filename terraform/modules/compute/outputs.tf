output "instance_id" {
  description = "Instance OCID"
  value       = oci_core_instance.control_plane.id
}

output "public_ip" {
  description = "Public IP address (ephemeral)"
  value       = oci_core_instance.control_plane.public_ip
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
