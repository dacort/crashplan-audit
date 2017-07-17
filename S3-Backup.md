That was fun.

Followed _some_ of this for the IAM stuff: http://parthicloud.com/how-to-access-s3-bucket-from-application-on-amazon-ec2-without-access-credentials/
Used this for the network: http://docs.aws.amazon.com/AmazonVPC/latest/UserGuide/VPC_Route_Tables.html

Had to create VPC.
Had to create Internet Gateway
Had to manually connect igw to vpc using 0.0.0.0/0

## Commands on host

- Verifying S3 IAM

```shell
 sudo apt install awscli
 aws s3 ls s3://crashplan-homebase/
```

- S3 Fuse

```shell
sudo apt install s3fs
sudo mkdir /mnt/crashplan-homebase && sudo chown ubuntu.ubuntu /mnt/crashplan-homebase
s3fs crashplan-homebase /mnt/crashplan-homebase -o iam_role=Crashplan-S3
```

Took a while to figure out the right incantation for the s3fs command.

- Crashplan

```shell
cd
mkdir Downloads && cd Downloads
wget https://download.code42.com/installs/linux/install/CrashPlan/CrashPlan_4.8.3_Linux.tgz
tar xzvf CrashPlan_4.8.3_Linux.tgz
cd crashplan-install

# Just accept the defaults.
sudo ./install.sh
```

If we want to do this as a permanent solution, we'd need to setup the incoming directory properly

```shell
# Crashplan installer has trouble reading from the s3fs
mkdir /mnt/crashplan-homebase/incoming && sudo ln -s /mnt/crashplan-homebase/incoming /usr/local/var/crashplan
```

- Do a restore
  - Make sure Crashplan is closed locally
  - Do all this stuff...

  ```shell
    cp /Library/Application\ Support/CrashPlan/.ui_info /Library/Application\ Support/CrashPlan/.ui_info.macos
    CP_KEY=$(ssh -i ~/Downloads/heresy-v2.pem ubuntu@52.39.172.82 cat /var/lib/crashplan/.ui_info | cut -f2 -d,)
    echo -n "4200,$CP_KEY,127.0.0.1" > /Library/Application\ Support/CrashPlan/.ui_info.linux
    ln -sf /Library/Application\ Support/CrashPlan/.ui_info.linux /Library/Application\ Support/CrashPlan/.ui_info
    cp /Library/Application\ Support/CrashPlan/ui_dacort.properties /Library/Application\ Support/CrashPlan/ui_dacort.properties.macos
    ssh -L 4200:localhost:4243 -i ~/Downloads/heresy-v2.pem ubuntu@52.39.172.82
  ```

  - Now open Crashplan and try to restore...

  It's not seeing anything in /mnt, so maybe try changing permissions....
  sudo s3fs crashplan-homebase /mnt/crashplan-homebase -o iam_role=Crashplan-S3,allow_other
