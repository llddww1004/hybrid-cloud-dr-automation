############################
# ALB (Internet-facing)
############################
resource "aws_lb" "app" {
  name               = "${var.project_name}-app-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = [var.public_subnet_a_id, var.public_subnet_c_id]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-app-alb"
  })
}

############################
# ③ SpringBoot Target Group (port 80 → 8080, 헬스체크 수정)
############################
resource "aws_lb_target_group" "springboot" {
  name     = "${var.project_name}-springboot-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path = "/actuator/health"
    port = "8080"
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-springboot-tg"
  })
}

############################
# ⑤ HAProxy Target Group (신규 추가)
############################
resource "aws_lb_target_group" "haproxy" {
  name     = "${var.project_name}-haproxy-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path = "/actuator/health"
    port = "80"
  }
}

############################
# ④ ALB Listener (dr_mode에 따라 타겟 그룹 전환)
############################
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = var.dr_mode ? aws_lb_target_group.springboot.arn : aws_lb_target_group.haproxy.arn
  }
}

############################
# ① SpringBoot Launch Template (app → springboot)
############################
resource "aws_launch_template" "springboot" {
  name_prefix   = "lt-${var.project_name}-springboot-"
  image_id      = var.springboot_ami_id
  instance_type = var.springboot_instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [var.springboot_sg_id]

  iam_instance_profile {
    name = aws_iam_instance_profile.springboot.name
  }

  user_data = base64encode(templatefile(
    "${path.module}/templates/springboot_user_data.sh.tpl",
    {
      jar_url      = var.springboot_jar_url
      github_token = var.github_token
      db_url       = var.rds_endpoint
      db_username  = var.db_username
      db_password  = var.db_password
    }
  ))

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 8
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge(var.common_tags, {
      Name = "${var.project_name}-springboot"
      Role = "springboot-server"
    })
  }

  update_default_version = true

  tags = merge(var.common_tags, {
    Name = "lt-${var.project_name}-springboot"
  })
}

############################
# ② SpringBoot Auto Scaling Group (app → springboot)
############################
resource "aws_autoscaling_group" "springboot" {
  name                      = "asg-${var.project_name}-springboot"
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  desired_capacity          = var.asg_desired_capacity
  vpc_zone_identifier       = [var.app_subnet_a_id, var.app_subnet_c_id]
  target_group_arns         = [aws_lb_target_group.springboot.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.springboot.id
    version = "$Default"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-springboot-asg"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "hybrid-dr"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

############################
# HAProxy Server
############################
resource "aws_instance" "haproxy" {
  ami                    = var.haproxy_ami_id
  instance_type          = "t3.micro"
  subnet_id              = var.haproxy_subnet_id
  vpc_security_group_ids = [var.haproxy_sg_id]
  key_name               = var.key_name

  user_data = <<-EOF
#!/bin/bash
dnf update -y
dnf install -y haproxy
curl -fsSL https://tailscale.com/install.sh | sh
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
sysctl -p
tailscale up --authkey=${var.tailscale_auth_key} --accept-routes
sleep 15
cat > /etc/haproxy/haproxy.cfg <<-HAPROXY
global
    log /dev/log local0
    maxconn 4096
    daemon
defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms
frontend http_front
    bind *:80
    default_backend onprem_back
backend onprem_back
    balance roundrobin
    option  httpchk GET /actuator/health
    server  onprem 100.79.94.82:8080 check
HAPROXY
systemctl enable haproxy
systemctl restart haproxy
EOF

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-haproxy"
    Role = "haproxy-proxy"
  })
}

resource "aws_lb_target_group_attachment" "haproxy" {
  target_group_arn = aws_lb_target_group.haproxy.arn
  target_id        = aws_instance.haproxy.id
  port             = 80
}

############################
# Bastion Host
############################
resource "aws_instance" "bastion" {
  ami                         = var.bastion_ami_id
  instance_type               = var.bastion_instance_type
  subnet_id                   = var.public_subnet_a_id
  key_name                    = var.key_name
  vpc_security_group_ids      = [var.bastion_sg_id]
  associate_public_ip_address = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-bastion"
    Role = "bastion"
  })
}

############################
# Jenkins Server
############################
resource "aws_instance" "jenkins" {
  ami                         = var.jenkins_ami_id
  instance_type               = var.jenkins_instance_type
  subnet_id                   = var.jenkins_subnet_id
  key_name                    = var.key_name
  vpc_security_group_ids      = [var.jenkins_sg_id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.jenkins.name

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-jenkins"
    Role = "jenkins"
  })
}

############################
# DB EC2 (MySQL + Tailscale)
############################
resource "aws_instance" "db_ec2" {
  ami                    = var.db_ec2_ami_id
  instance_type          = "t3.micro"
  subnet_id              = var.db_ec2_subnet_id
  vpc_security_group_ids = [var.db_ec2_sg_id]
  key_name               = var.key_name
  private_ip             = var.db_ec2_private_ip

  user_data = <<-EOF
#!/bin/bash
dnf update -y
rpm -Uvh https://dev.mysql.com/get/mysql80-community-release-el9-1.noarch.rpm
dnf install -y mysql-community-server --nogpgcheck

############################
# Phase 1: 초기화용 설정 (binlog OFF, GTID OFF)
############################
cat > /etc/my.cnf.d/replication.cnf << 'MYCNF'
[mysqld]
server-id=2
skip-log-bin
MYCNF

echo '!includedir /etc/my.cnf.d/' >> /etc/my.cnf

systemctl enable mysqld
systemctl start mysqld
sleep 10

# 비밀번호 초기화 (binlog 꺼져있어서 기록 안 됨)
TEMP_PASS=$(grep 'temporary password' /var/log/mysqld.log | awk '{print $NF}')
mysql -u root -p"$TEMP_PASS" --connect-expired-password -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'TempPass123!';"
mysql -u root -p"TempPass123!" -e "SET GLOBAL validate_password.policy=LOW;"
mysql -u root -p"TempPass123!" -e "SET GLOBAL validate_password.length=4;"
mysql -u root -p"TempPass123!" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${var.db_password}';"

# DB EC2 자체 repl_user 생성 (RDS가 DB EC2에 접속할 때 사용)
mysql -u root -p"${var.db_password}" -e "
CREATE USER 'repl_user'@'%' IDENTIFIED WITH mysql_native_password BY '${var.db_password}';
GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';
FLUSH PRIVILEGES;
"

############################
# Phase 2: 본 설정 덮어쓰고 재시작 (binlog ON, GTID ON)
############################
cat > /etc/my.cnf.d/replication.cnf << 'MYCNF'
[mysqld]
server-id=2
log-bin=mysql-bin
binlog-format=ROW
gtid-mode=ON
enforce-gtid-consistency=ON
log_slave_updates=ON
MYCNF

systemctl restart mysqld
sleep 10

############################
# Phase 3: Tailscale
############################
curl -fsSL https://tailscale.com/install.sh | sh
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
sysctl -p
tailscale up --authkey=${var.tailscale_auth_key} --accept-routes
sleep 30

############################
# Replication 설정 — Jenkins Pipeline 담당 (Terraform 범위 외)
# ============================================================
# 이 Terraform 코드는 "Replication 가능한 MySQL 인프라" 까지만 프로비저닝합니다.
# 실제 Replication 실행(dump, CHANGE MASTER, START SLAVE, RDS 프로시저 등)은
# Jenkins 파이프라인이 담당합니다.
#
# Jenkins 파이프라인 책임:
#   • setup-replication : 온프렘 → DB EC2 → RDS 초기 동기화
#   • failover          : DB EC2 STOP SLAVE + RDS Master 승격
#   • failback          : 역방향 동기화 후 정방향 재구성
#
# 역할 분리 원칙:
#   - Terraform (인프라 엔지니어): 인프라 세팅만
#     (MySQL 설치, GTID/binlog 활성, repl_user, Tailscale)
#   - Jenkins (CI/CD 담당자): Replication 실행 + 운영
#     (dump 생성/import, CHANGE MASTER, START REPLICA, RDS 프로시저)
#
# 현재 인프라 상태 (apply 완료 후 기대값):
#   ✅ MySQL running + GTID/binlog ON + log_slave_updates
#   ✅ repl_user 계정 준비됨 (REPLICATION SLAVE 권한)
#   ✅ Tailscale 메시 연결 (Jenkins가 SSH+SQL 접속 가능)
#   ❌ SHOW SLAVE STATUS = Empty (의도적 — Jenkins 셋업 대기)
#   ❌ DB 데이터 없음 (의도적 — Jenkins setup-replication 에서 초기 dump)
############################
echo "[INFO] DB EC2 인프라 세팅 완료 (MySQL + GTID + repl_user + Tailscale)"
echo "[INFO] Replication 실행은 Jenkins setup-replication 파이프라인에서 담당"
EOF

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-db-ec2"
    Role = "db-replication"
  })
}
