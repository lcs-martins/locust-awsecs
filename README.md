# locust-awsecs
TF code to deploy locust in a AWS ECS stack based on fargate.


### Runnig local first, and test you script: 

##### Requirements:
+ Docker running

##### 1 master and 1 worker
```
docker-compose up
```

##### 1 master and 4 worker
```
docker-compose up --scale workers=4
```

### Runnig in AWS:

##### Requirements:
+ Docker running

#### just planning
```
terraform plan --var-file global.tfvars
```


#### Deploy
```
terraform apply --var-file global.tfvars
```