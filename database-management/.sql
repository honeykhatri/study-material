✅ Lesson 1: Basic SELECT Queries
🧠 Concept:
The SELECT statement is used to fetch data from a database.
  🗂️ Sample Table: employees
id	name	department	salary
1	Alice	HR	50000
2	Bob	IT	60000
3	Charlie	IT	55000
4	Diana	Finance	70000

Write a query to select the names and departments of all employees.
SELECT name, department FROM employees;

Write a query to find the employee(s) who work in the Finance department.
SELECT * FROM employees WHERE department = 'Finance';

Write a query to get the names of employees who earn less than 60000.
SELECT name FROM employees WHERE salary < 60000;

Write a query to get all details of employees whose name starts with 'D'.
  SELECT * FROM employees WHERE name LIKE 'D%';

Get the names and salaries of employees in the HR or Finance departments.
  SELECT name, salary FROM employees WHERE department IN ('HR', 'Finance');

Get all details of employees with a salary between 50000 and 60000 (inclusive).
  SELECT * FROM employees WHERE salary >= 50000 AND salary <= 60000;

Get the names of employees not in the IT department.
  SELECT name FROM employees WHERE department NOT IN ('IT');

Get the names of employees whose names end with 'e'.
  SELECT name FROM employees WHERE name LIKE '%e';


🔹 1. ORDER BY
Used to sort the result set by one or more columns.

🔹 2. LIMIT
Used to restrict the number of rows returned.

  🔹 3. GROUP BY
Used to group rows that have the same values in specified columns, often used with aggregate functions like COUNT(), SUM(), AVG().

Get all employee details, sorted by salary in descending order.
  SELECT * FROM employees ORDER BY salary DESC;

Get the top 2 highest-paid employees.
  SELECT * FROM employees ORDER BY salary DESC LIMIT 2;

Get the average salary for each department.
  SELECT AVG(salary) FROM employees GROUP BY department;
SELECT department, AVG(salary) FROM employees GROUP BY department;

Get the number of employees in each department.
SELECT department, COUNT(*) FROM employees GROUP BY department;


🔗 What is a JOIN?
A JOIN lets you combine rows from two or more tables based on a related column between them.
