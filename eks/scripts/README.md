# AWS Tools

Collection of AWS analysis and management tools.

## CloudWatch Logs Usage & Cost Analysis

**Script:** `cw_status_projection.sh`

Comprehensive CloudWatch Logs analysis tool that provides detailed usage metrics, cost projections, and optimization recommendations.

### Features

- **Executive Summary**: High-level overview of usage and costs
- **30-Day Historical Trends**: Daily ingestion breakdown with visual ASCII chart
  - Weekly trend analysis (comparing last 4 weeks)
  - Anomaly detection for unusual spikes
  - Trend indicators (increasing/stable/decreasing)
- **Service Breakdown**: Analysis by AWS service type (Lambda, EKS, RDS, VPC, etc.)
- **Top Consumers**: Identifies highest-cost log groups
- **Retention Analysis**: Reviews retention policies and their cost impact
- **Cost Projections**: Monthly and yearly cost estimates
- **Optimization Recommendations**: Actionable suggestions to reduce costs
- **Free Tier Tracking**: Shows usage relative to AWS free tier limits

### Usage

```bash
# Basic usage (analyzes last 7 days)
./aws/cw_status_projection.sh

# Custom time window (14 days)
WINDOW_DAYS=14 ./aws/cw_status_projection.sh

# Different region
AWS_REGION=us-east-1 ./aws/cw_status_projection.sh

# Include detailed log group listing
DETAILED=1 ./aws/cw_status_projection.sh

# Combine options
AWS_REGION=eu-west-1 WINDOW_DAYS=30 DETAILED=1 ./aws/cw_status_projection.sh
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `us-west-2` | AWS region to analyze |
| `WINDOW_DAYS` | `7` | Number of days to analyze for trend projection |
| `DETAILED` | `0` | Set to `1` to show full log group listing |

### Requirements

- AWS CLI configured with valid credentials
- `bc` command for calculations (optional but recommended)
  - macOS: `brew install bc`
  - Linux: Usually pre-installed
- For macOS: `coreutils` for date handling
  - Install: `brew install coreutils`

### Output Sections

#### 1. Executive Summary
- Total log groups
- Storage and ingestion metrics
- Monthly and yearly cost projections
- Free tier status

#### 2. 30-Day Historical Trends (NEW!)
- **Summary Statistics**: Average, peak, minimum daily ingestion
- **Weekly Breakdown**: Compare last 4 weeks to identify trends
- **Trend Indicator**: Visual indication if usage is increasing/stable/decreasing
- **ASCII Chart**: Daily ingestion visualized with color-coded bars
  - Green: Normal usage (below 1.2x average)
  - Yellow: Elevated usage (1.2x-1.5x average)
  - Red: High usage (above 1.5x average)
- **Anomaly Detection**: Automatically flags days with unusual spikes (>2x average)
- Helps identify:
  - Gradual increases in log volume over time
  - Seasonal patterns or weekly cycles
  - Deployment-related spikes
  - Potential runaway logging

#### 3. Service Breakdown
- Usage grouped by service type (Lambda, EKS, etc.)
- Per-service costs

#### 4. Top Consumers
- Top 10 log groups by projected monthly ingestion
- Individual cost estimates

#### 5. Retention Analysis
- Storage costs grouped by retention period
- Identifies groups with no retention policy

#### 6. Optimization Recommendations
- Set retention policies for unlimited-retention groups
- Review high-volume log groups
- VPC Flow Logs optimization tips
- General best practices
- Cost comparison (CloudWatch vs S3)

#### 7. Detailed Listing (optional)
- Complete list of all log groups with metrics
- Sorted by projected usage

### Cost Calculations

The script uses standard AWS CloudWatch Logs pricing (us-east-1):

- **Ingestion**: $0.50 per GB
- **Storage**: $0.03 per GB-month
- **Free Tier**:
  - 5 GB ingestion per month
  - 5 GB storage

**Note**: Prices may vary by region. Update the script variables if needed:
```bash
INGEST_PRICE_PER_GB=0.50
STORAGE_PRICE_PER_GB=0.03
```

### Example Output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📊 CloudWatch Logs Analysis - Executive Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Region                   : us-west-2
Analysis Window          : 7 days
Period                   : 2025-11-02T10:00:00Z to 2025-11-09T10:00:00Z

▶ 📈 Usage Metrics

  Total Log Groups                  :     42
  Currently Stored                  :      12.45 GB
  Ingested (7d window)              :       3.21 GB
  Projected 30-day Ingestion        :      13.76 GB

▶ 💰 Cost Projections (Monthly)

  Storage Cost                      :  $    0.37
  Ingestion Cost                    :  $    4.38
  Total Monthly Cost                :  $    4.75
  Projected Yearly Cost             :  $   57.00
```

### Optimization Tips

1. **Set Retention Policies**
   - Log groups with no retention policy store logs indefinitely
   - Common retention periods: 7, 30, 90, or 365 days
   - Command to set retention:
     ```bash
     aws logs put-retention-policy \
       --log-group-name /aws/lambda/my-function \
       --retention-in-days 30
     ```

2. **Reduce Log Verbosity**
   - Lambda: Use INFO or WARN instead of DEBUG
   - Set environment variable: `LOG_LEVEL=INFO`

3. **VPC Flow Logs**
   - Use custom format with only required fields
   - Enable for specific subnets, not entire VPCs
   - Consider shorter retention (7 days instead of 30)

4. **Archive to S3**
   - For logs older than 30 days, export to S3
   - S3 Standard: ~$0.023/GB-month (vs CloudWatch $0.03)
   - S3 Glacier: ~$0.004/GB-month for archives

5. **Use Subscription Filters**
   - Stream logs to S3, Kinesis, or Lambda
   - Process logs in real-time, store elsewhere
   - Example:
     ```bash
     aws logs put-subscription-filter \
       --log-group-name /aws/lambda/my-function \
       --filter-name SendToS3 \
       --filter-pattern "" \
       --destination-arn arn:aws:kinesis:region:account:stream/name
     ```

### Troubleshooting

**Error: "Missing aws CLI"**
- Install AWS CLI: https://aws.amazon.com/cli/

**Error: "Missing bc command"**
- macOS: `brew install bc`
- Ubuntu/Debian: `sudo apt-get install bc`
- RHEL/CentOS: `sudo yum install bc`

**Slow execution**
- Analysis time depends on number of log groups
- Historical trends collection queries each log group for 30 days of data
  - With many log groups (50+), this can take several minutes
  - Progress indicators show current status
- Use smaller `WINDOW_DAYS` for faster current usage analysis (doesn't affect historical trends)
- Consider running during off-peak hours

**Different costs than expected**
- Check your region's pricing: https://aws.amazon.com/cloudwatch/pricing/
- Update script variables for your region
- Costs exclude data transfer and API request charges

### Related Commands

```bash
# List all log groups
aws logs describe-log-groups --region us-west-2

# Get specific log group details
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/

# Set retention policy
aws logs put-retention-policy --log-group-name NAME --retention-in-days 30

# Delete log group
aws logs delete-log-group --log-group-name NAME

# Export logs to S3
aws logs create-export-task \
  --log-group-name NAME \
  --from $(date -d '7 days ago' +%s)000 \
  --to $(date +%s)000 \
  --destination your-s3-bucket \
  --destination-prefix cloudwatch-logs/
```

### See Also

- [AWS CloudWatch Logs Pricing](https://aws.amazon.com/cloudwatch/pricing/)
- [CloudWatch Logs User Guide](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/)
- [Best Practices for CloudWatch Logs](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/WhatIsCloudWatchLogs.html)

