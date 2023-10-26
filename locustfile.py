from locust import HttpUser, between, task

# target: reqres.in

class WebsiteUser(HttpUser):
    wait_time = between(5, 15)
    
    def on_start(self):
        self.client.post("/api/login", {
            "email": "eve.holt@reqres.in",
            "password": "cityslicka"
        })
    
    @task
    def index(self):
        self.client.get("/api/users")
        self.client.get("/api/users?page=2")
        
    @task
    def about(self):
        self.client.get("/api/users/7")