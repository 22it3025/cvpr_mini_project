import mysql.connector
import os
import openpyxl
import re
from dotenv import load_dotenv

# Load DB credentials from .env
load_dotenv()

DB_HOST = os.getenv("DB_HOST")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")
DB_NAME = os.getenv("DB_NAME")

SUBJECT_RE = re.compile(r'^[A-Za-z0-9_]+$')

def read_rollnos_from_file(filepath):
    ext = os.path.splitext(filepath)[1].lower()
    rollnos = []

    if ext == '.txt':
        with open(filepath, 'r') as f:
            rollnos = [line.strip().upper() for line in f if line.strip()]
    elif ext == '.xlsx':
        workbook = openpyxl.load_workbook(filepath)
        sheet = workbook.active
        for row in sheet.iter_rows(min_row=2, values_only=True):  # Skip header
            if row and row[0]:
                rollnos.append(str(row[0]).strip().upper())
    else:
        raise ValueError("Unsupported file type. Use .txt or .xlsx")

    return rollnos

def sanitize_subject_code(s):
    s = s.strip().upper()
    if not SUBJECT_RE.match(s):
        raise ValueError("Invalid subject code. Only letters, numbers and underscore allowed.")
    return s

def get_db_connection():
    return mysql.connector.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME
    )

def create_attendance_table(filepath, subject_code):
    subject_code = sanitize_subject_code(subject_code)
    table_name = f"attendance_{subject_code}"   # use lowercase/consistent naming if you like
    rollnos = read_rollnos_from_file(filepath)

    conn = None
    cursor = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        # Ensure parent table engine is InnoDB (FKs require InnoDB)
        cursor.execute("ALTER TABLE student_subject_enrollment ENGINE = InnoDB;")

        # Create attendance table with composite PK and composite FK that matches parent PK
        create_sql = f"""
        CREATE TABLE IF NOT EXISTS `{table_name}` (
            rollno VARCHAR(20) NOT NULL,
            subject_code VARCHAR(20) NOT NULL,
            PRIMARY KEY (rollno, subject_code),
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            CONSTRAINT `{table_name}_fk_enroll`
                FOREIGN KEY (rollno, subject_code)
                REFERENCES student_subject_enrollment(rollno, subject_code)
                ON DELETE CASCADE
                ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        """
        cursor.execute(create_sql)
        print(f"[INFO] Ensured table `{table_name}` exists with composite FK -> student_subject_enrollment(rollno, subject_code).")

        # Insert only rollnos that are enrolled for this subject.
        # We use INSERT ... SELECT so nothing will be inserted if the rollno is not enrolled.
        insert_sql = f"""
        INSERT IGNORE INTO `{table_name}` (rollno, subject_code)
        SELECT %s, %s
        FROM student_subject_enrollment
        WHERE rollno = %s AND subject_code = %s
        """
        invalid_rollnos = []
        for r in rollnos:
            # execute the INSERT SELECT with parameters — returns affected rows if inserted
            cursor.execute(insert_sql, (r, subject_code, r, subject_code))
            # If nothing was inserted, the student wasn't found in enrollment for this subject
            if cursor.rowcount == 0:
                invalid_rollnos.append(r)

        conn.commit()

        print(f"✅ Table '{table_name}' created/updated with valid roll numbers.")
        if invalid_rollnos:
            print("\n❌ These roll numbers were not found in Student_Subject_Enrollment for subject", subject_code, "and were skipped:")
            for r in invalid_rollnos:
                print(" -", r)

    except mysql.connector.Error as err:
        print(f"[ERROR] MySQL Error: {err}")
    except Exception as e:
        print(f"[ERROR] {e}")
    finally:
        if cursor: cursor.close()
        if conn: conn.close()

# 🧪 Run
if __name__ == "__main__":
    subject_code = input("Enter subject code (e.g., CS101): ").strip()
    filepath = input("Enter path to student roll number file (.txt or .xlsx): ").strip()
    create_attendance_table(filepath, subject_code)
