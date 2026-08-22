# Rebecca SQLite → MySQL Migration

A one-click migration tool for moving **Rebecca Panel** from **SQLite** to **MySQL** with automatic backup, validation, rollback, and MySQL reinstallation support.

ابزاری برای مهاجرت خودکار **Rebecca Panel** از **SQLite** به **MySQL** همراه با بکاپ، بررسی صحت داده‌ها، Rollback خودکار و نصب مجدد MySQL.

---

# 🇮🇷 فارسی

## پیش‌نیازها

قبل از شروع، سرور باید شرایط زیر را داشته باشد:

* Ubuntu / Debian
* نصب Rebecca به‌صورت **Binary**
* دیتابیس فعلی Rebecca از نوع **SQLite**
* دسترسی `root`
* دسترسی اینترنت به GitHub و Repositoryهای سیستم‌عامل

> **توجه مهم:**
> دستور نصب خودکار زیر اجازه دارد در صورت وجود MySQL یا MariaDB قبلی، ابتدا از اطلاعات قابل دسترس آن بکاپ گرفته و سپس آن را حذف کند تا MySQL جدید و تمیز نصب شود.

---

## 🚀 نصب و مهاجرت کاملاً خودکار

اگر با کاربر `root` وارد سرور هستید، فقط دستور زیر را اجرا کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/mansourganjipoor/Rebecca-Tools/main/rebecca-sqlite-to-mysql.sh | PURGE_EXISTING_MYSQL=YES bash
```

اسکریپت به‌صورت خودکار مراحل زیر را انجام می‌دهد:

* شناسایی نصب فعلی Rebecca
* بررسی SQLite بودن دیتابیس
* تشخیص خودکار نسخه Goose
* بررسی سیستم‌عامل و پکیج‌های موردنیاز
* شناسایی MySQL یا MariaDB قبلی
* تهیه بکاپ از MySQL/MariaDB و تنظیمات آن در صورت امکان
* حذف نصب قبلی MySQL/MariaDB
* نصب و تنظیم یک MySQL جدید
* توقف کنترل‌شده Rebecca
* تهیه بکاپ سازگار از SQLite
* تهیه بکاپ از فایل `.env`
* ساخت دیتابیس و کاربر MySQL
* اجرای Migration رسمی خود Rebecca
* مقایسه ساختار SQLite و MySQL
* انتقال اطلاعات SQLite به MySQL
* تبدیل خودکار فرمت‌های ناسازگار تاریخ و زمان
* بررسی تعداد رکوردهای منتقل‌شده
* بررسی نسخه Goose
* تغییر تنظیمات Rebecca از SQLite به MySQL
* اجرای مجدد Rebecca
* بررسی نهایی عملکرد دیتابیس
* بازگرداندن Rebecca به SQLite در صورت شکست مهاجرت قبل از تکمیل

---

## 🛠 نصب و اجرای دستی

اگر ترجیح می‌دهید ابتدا فایل را دانلود و بررسی کرده و سپس اجرا کنید، از روش زیر استفاده کنید.

### ۱. دانلود اسکریپت

```bash
curl -fsSL https://raw.githubusercontent.com/mansourganjipoor/Rebecca-Tools/main/rebecca-sqlite-to-mysql.sh \
-o /root/rebecca-sqlite-to-mysql.sh
```

### ۲. دادن مجوز اجرا

```bash
chmod +x /root/rebecca-sqlite-to-mysql.sh
```

### ۳. اجرای مهاجرت

```bash
PURGE_EXISTING_MYSQL=YES /root/rebecca-sqlite-to-mysql.sh
```


---

## 💾 بکاپ

اسکریپت دیتابیس اصلی SQLite را حذف نمی‌کند.

یک پوشه بکاپ با نامی مشابه زیر ساخته می‌شود:

```text
/root/rebecca-sqlite-to-mysql-YYYYMMDD-HHMMSS/
```

بسته به وضعیت سرور، این پوشه می‌تواند شامل موارد زیر باشد:

```text
db.sqlite3
original.env
env-before-mysql
MySQL configuration backup
MySQL/MariaDB backup
migration logs
```

پیشنهاد می‌شود تا زمانی که از عملکرد کامل MySQL مطمئن نشده‌اید، این بکاپ‌ها را حذف نکنید.

---

## ⚠️ هشدار مهم

متغیر زیر:

```text
PURGE_EXISTING_MYSQL=YES
```

به اسکریپت اجازه می‌دهد MySQL یا MariaDB موجود روی سرور را، پس از تلاش برای تهیه بکاپ، حذف کرده و یک MySQL جدید نصب کند.

بنابراین روی سروری که MySQL آن برای سرویس‌های دیگری نیز استفاده می‌شود، بدون بررسی قبلی این دستور را اجرا نکنید.

برای سرورهای Production همیشه علاوه بر بکاپ خود اسکریپت، یک Snapshot یا Backup خارجی از سرور داشته باشید.

---

## ✅ نتیجه نهایی

پس از مهاجرت موفق:

```text
Rebecca Panel
      │
      ▼
MySQL
Host: 127.0.0.1
Database: rebecca
User: rebecca
```
## 🇬🇧 English

### Requirements

Before starting, make sure your server meets the following requirements:

* Ubuntu / Debian
* Rebecca Panel installed in **Binary mode**
* Current Rebecca database is **SQLite**
* Root access
* Internet access to GitHub and your Linux package repositories

> **Important:**
> The automatic installation command below is allowed to back up and remove an existing MySQL/MariaDB installation before installing a clean MySQL instance.

---

## 🚀 Automatic Installation

Run the following command as `root`:

```bash
curl -fsSL https://raw.githubusercontent.com/mansourganjipoor/Rebecca-Tools/main/rebecca-sqlite-to-mysql.sh | PURGE_EXISTING_MYSQL=YES bash
```

The script will automatically:

* Detect your current Rebecca installation
* Verify that Rebecca is using SQLite
* Detect the current Goose migration version
* Check system and package requirements
* Detect an existing MySQL/MariaDB installation
* Back up existing MySQL/MariaDB data and configuration when possible
* Remove the previous MySQL/MariaDB installation
* Install and configure a clean MySQL server
* Create a consistent SQLite backup
* Back up the Rebecca `.env` configuration
* Create the MySQL database and user
* Run Rebecca's official database migrations
* Compare SQLite and MySQL schemas
* Transfer application data from SQLite to MySQL
* Convert incompatible datetime values automatically
* Validate row counts after migration
* Verify the Goose migration version
* Switch Rebecca to MySQL
* Start Rebecca and perform final validation
* Roll back Rebecca to SQLite if migration fails before completion

---

## 🛠 Manual Installation

If you prefer to download and inspect the script before running it:

### 1. Download the script

```bash
curl -fsSL https://raw.githubusercontent.com/mansourganjipoor/Rebecca-Tools/main/rebecca-sqlite-to-mysql.sh \
-o /root/rebecca-sqlite-to-mysql.sh
```

### 2. Make it executable

```bash
chmod +x /root/rebecca-sqlite-to-mysql.sh
```

### 3. Run the migration

```bash
PURGE_EXISTING_MYSQL=YES /root/rebecca-sqlite-to-mysql.sh
```

---

## 🌐 Optional: Custom Ubuntu Mirror

If your server has connectivity problems with the default Ubuntu repositories, you can specify a custom mirror.

Example:

```bash
curl -fsSL https://raw.githubusercontent.com/mansourganjipoor/Rebecca-Tools/main/rebecca-sqlite-to-mysql.sh \
| env PURGE_EXISTING_MYSQL=YES \
APT_MIRROR=https://repo.iut.ac.ir/ubuntu \
bash
```

---

## 💾 Backup

The original SQLite database is **not deleted**.

A backup directory is automatically created with a name similar to:

```text
/root/rebecca-sqlite-to-mysql-YYYYMMDD-HHMMSS/
```

Depending on the server state, it may contain:

```text
db.sqlite3
original.env
env-before-mysql
mysql configuration backup
MySQL/MariaDB backup
migration logs
```

Keep this directory until you are completely sure the migration was successful.

---

## ⚠️ Important Warning

Do not run the migration command on a server that is already using MySQL unless you understand the consequences.

The option:

```text
PURGE_EXISTING_MYSQL=YES
```

explicitly allows the script to back up and remove the existing MySQL/MariaDB installation before preparing a clean database environment.

Always keep an external server backup before performing database migrations on production systems.

