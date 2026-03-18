provider "aws" {
  region = var.region
}

data "aws_ami" "windows_ami" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }
}

data "http" "local_ip" {
  url = "https://api.ipify.org?format=json"
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  availability_zones           = length(var.allowed_availability_zone_identifier) != 0 ? var.allowed_availability_zone_identifier : [for az in data.aws_availability_zones.available.names : substr(az, -1, 1)]
  availability_zone_identifier = element(local.availability_zones, random_integer.az_id.result)
  availability_zone            = "${var.region}${local.availability_zone_identifier}"

  local_ip = jsondecode(data.http.local_ip.response_body).ip

  ports = {
    "rdp" : {
      "tcp" : [{ "port" = 3389, "description" = "RDP", }, ],
    },
    "vnc" : {
      "tcp" : [{ "port" = 5900, "description" = "VNC", }, ],
    },
    "steam_link" : {
      "tcp" : [
        { "port" = 27036, "description" = "Steam Link Discovery/Control", },
        { "port" = 27037, "description" = "Steam Link Streaming", },
      ],
      "udp" : [
        { "port" = 27031, "description" = "Steam Link Discovery", },
        { "port" = 27032, "description" = "Steam Link Discovery", },
        { "port" = 27033, "description" = "Steam Link Discovery", },
        { "port" = 27034, "description" = "Steam Link Discovery", },
        { "port" = 27035, "description" = "Steam Link Discovery", },
        { "port" = 27036, "description" = "Steam Link Discovery", },
      ],
    },
    "sunshine" : {
      "tcp" : [
        { "port" = 47984, "description" = "HTTPS", },
        { "port" = 47989, "description" = "HTTP", },
        { "port" = 47990, "description" = "Web", },
        { "port" = 48010, "description" = "RTSP", },
      ],
      "udp" : [
        { "port" = 47998, "description" = "Video", },
        { "port" = 47999, "description" = "Control", },
        { "port" = 48000, "description" = "Audio", },
        { "port" = 48002, "description" = "Mic (unused)", },
      ],
    },
  }
}

resource "random_integer" "az_id" {
  min = 0
  max = length(local.availability_zones)
}

resource "random_password" "password" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "password" {
  name  = "${var.resource_name}-administrator-password"
  type  = "SecureString"
  value = random_password.password.result

  tags = {
    App = "cloudrig"
  }
}

resource "aws_security_group" "default" {
  name = "${var.resource_name}-sg"

  tags = {
    App = "cloudrig"
  }
}

# Allow inbound connections from the local IP
resource "aws_security_group_rule" "ingress" {
  for_each = {
    for port in flatten(
      [
        for app, protocols in local.ports : [
          for protocol, ports in protocols : [
            for port in ports : {
              name        = join("_", [app, protocol, port.port]),
              app         = app,
              protocol    = protocol,
              port        = port.port,
              description = port.description
            }
          ]
        ]
      ]
    ) : join("_", [port.app, port.protocol, port.port]) => port
  }
  type              = "ingress"
  description       = each.value.description
  from_port         = each.value.port
  to_port           = each.value.port
  protocol          = each.value.protocol
  cidr_blocks       = ["${local.local_ip}/32"]
  security_group_id = aws_security_group.default.id
}

# Allow outbound connection to everywhere
resource "aws_security_group_rule" "egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.default.id
}

resource "aws_iam_role" "windows_instance_role" {
  name               = "${var.resource_name}-instance-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

  tags = {
    App = "cloudrig"
  }
}

resource "aws_iam_policy" "password_get_parameter_policy" {
  name   = "${var.resource_name}-password-get-parameter-policy"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ssm:GetParameter",
      "Resource": "${aws_ssm_parameter.password.arn}"
    }
  ]
}
EOF
}

data "aws_iam_policy" "driver_get_object_policy" {
  arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "password_get_parameter_policy_attachment" {
  role       = aws_iam_role.windows_instance_role.name
  policy_arn = aws_iam_policy.password_get_parameter_policy.arn
}

resource "aws_iam_role_policy_attachment" "driver_get_object_policy_attachment" {
  role       = aws_iam_role.windows_instance_role.name
  policy_arn = data.aws_iam_policy.driver_get_object_policy.arn
}

resource "aws_iam_instance_profile" "windows_instance_profile" {
  name = "${var.resource_name}-instance-profile"
  role = aws_iam_role.windows_instance_role.name
}

data "aws_ebs_snapshot_ids" "games" {
  filter {
    name   = "tag:Name"
    values = ["${var.resource_name}-games-snapshot"]
  }
  filter {
    name   = "status"
    values = ["completed"]
  }
}

data "aws_ebs_snapshot" "games" {
  count       = length(data.aws_ebs_snapshot_ids.games.ids) > 0 ? 1 : 0
  most_recent = true

  filter {
    name   = "tag:Name"
    values = ["${var.resource_name}-games-snapshot"]
  }
}

resource "aws_ebs_volume" "games" {
  availability_zone = local.availability_zone
  size              = var.games_volume_size_gb
  type              = "gp3"
  snapshot_id       = length(data.aws_ebs_snapshot.games) > 0 ? data.aws_ebs_snapshot.games[0].id : null

  tags = {
    Name = "${var.resource_name}-games"
    App  = "cloudrig"
  }
}

locals {
  user_data = var.skip_install ? "" : templatefile(
    "${path.module}/templates/user_data.tpl",
    {
      password_ssm_parameter        = aws_ssm_parameter.password.name,
      region                        = var.region,
      games_volume_drive            = "D",
      idle_shutdown_timeout_minutes = var.idle_shutdown_timeout_minutes,
      var = {
        instance_type               = var.instance_type,
        install_parsec              = var.install_parsec,
        install_auto_login          = var.install_auto_login,
        install_graphic_card_driver = var.install_graphic_card_driver,
        install_steam               = var.install_steam,
        install_gog_galaxy          = var.install_gog_galaxy,
        install_ea_app              = var.install_ea_app,
        install_epic_games_launcher = var.install_epic_games_launcher,
        install_uplay               = var.install_uplay,
      }
    }
  )

  instance_id         = try(aws_spot_instance_request.windows_instance[0].spot_instance_id, aws_instance.windows_instance[0].id, "")
  instance_ip         = try(aws_eip.instance.public_ip, "")
  instance_public_dns = try(aws_eip.instance.public_dns, "")
}

resource "aws_spot_instance_request" "windows_instance" {
  count = var.use_spot_instance ? 1 : 0

  instance_type        = var.instance_type
  availability_zone    = local.availability_zone
  ami                  = (length(var.custom_ami) > 0) ? var.custom_ami : data.aws_ami.windows_ami.image_id
  security_groups      = [aws_security_group.default.name]
  user_data            = local.user_data
  iam_instance_profile = aws_iam_instance_profile.windows_instance_profile.id

  # Spot configuration
  spot_type            = "one-time"
  wait_for_fulfillment = true

  # EBS configuration
  ebs_optimized = true
  root_block_device {
    volume_size = var.root_block_device_size_gb
  }

  tags = {
    Name = "${var.resource_name}-instance"
    App  = "cloudrig"
  }
}

resource "aws_instance" "windows_instance" {
  count = var.use_spot_instance ? 0 : 1

  instance_type        = var.instance_type
  availability_zone    = local.availability_zone
  ami                  = (length(var.custom_ami) > 0) ? var.custom_ami : data.aws_ami.windows_ami.image_id
  security_groups      = [aws_security_group.default.name]
  user_data            = local.user_data
  iam_instance_profile = aws_iam_instance_profile.windows_instance_profile.id

  # EBS configuration
  ebs_optimized = true
  root_block_device {
    volume_size = var.root_block_device_size_gb
  }

  tags = {
    Name = "${var.resource_name}-instance"
    App  = "cloudrig"
  }
}

resource "aws_eip" "instance" {
  domain = "vpc"

  tags = {
    Name = "${var.resource_name}-eip"
    App  = "cloudrig"
  }
}

resource "aws_eip_association" "instance" {
  allocation_id = aws_eip.instance.id
  instance_id   = local.instance_id
}

resource "aws_volume_attachment" "games" {
  device_name  = "/dev/xvdf"
  volume_id    = aws_ebs_volume.games.id
  instance_id  = local.instance_id
  force_detach = true
}

output "instance_id" {
  value = local.instance_id
}

output "instance_ip" {
  value = local.instance_ip
}

output "instance_public_dns" {
  value = local.instance_public_dns
}

output "instance_password" {
  value     = random_password.password.result
  sensitive = true
}

output "games_volume_id" {
  value = aws_ebs_volume.games.id
}

output "rdp_command" {
  value = "mstsc /v:${local.instance_ip}  (User: Administrator, Password: terraform output -raw instance_password)"
}
