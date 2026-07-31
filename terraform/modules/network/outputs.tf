output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet ids, one per AZ (index 0 = azs[0])."
  value       = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  value = aws_subnet.data[*].id
}

output "private_route_table_id" {
  description = "Private route table; the bastion-nat module adds its default route here."
  value       = aws_route_table.private.id
}

output "igw_id" {
  value = aws_internet_gateway.this.id
}
