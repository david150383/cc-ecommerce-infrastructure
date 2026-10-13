// Creates the Order Service database user. It can access only order_db.
// LOCAL DEVELOPMENT PASSWORD ONLY.
db = db.getSiblingDB("order_db");
db.createUser({
  user: "order_svc",
  pwd: "order_local_pw",
  roles: [{ role: "readWrite", db: "order_db" }, { role: "dbAdmin", db: "order_db" }],
});
