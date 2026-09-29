# Blog Writing Style

I am the writer of this blog, and its audience is public. Most posts describe how I set up and run my own systems, such as my homelab, so that other engineers can learn from them or build something similar.

Posts are written in my voice. "I" in a post always refers to me.

These posts exist primarily to share knowledge and document things learned while working with technology.

Write as an engineer sharing something useful with another engineer.

The goal is not to produce exhaustive tutorials, definitive guides, or long-form educational content. Each post should capture one useful idea, technique, problem, solution, or lesson clearly enough that another person can understand it and use it.

## Keeping Private Details Out

Anyone can read these posts. Show how I set things up without revealing the details of my real environment.

Never publish:

* **Addresses:** IP and MAC addresses of my machines, whether LAN, public, or Tailscale.
* **Names:** real hostnames, internal domains, tailnet names, and my login usernames.
* **Accounts:** email addresses, cloud account IDs, and ARNs or URLs that contain them.
* **Secrets:** keys, tokens, passwords, kubeconfigs, runner registration details, and decoded `Secret` values.
* **Local paths:** where my private keys and backups actually live.
* **Unfixed weaknesses:** gaps in my setup that are still open, such as a stale rule left in a live policy.

This applies to prose, commands, command output, config files, and screenshots.

Use placeholders instead:

* **Values the reader must replace:** angle-bracket placeholders such as `<server-ip>`, `<tailscale-ip>`, and `<token>`. List them near the top of the post.
* **Everything else:** generic names such as `admin`, `node-01`, `homelab`, and `example.com`.

Scripts and configs next to a post are my real files with private values replaced by placeholders.

Fine to show:

* Well-known defaults, such as the k3s pod and service CIDRs.
* A common subnet such as `192.168.1.0/24` as a script default, where a placeholder would break the script.
* Problems I have already fixed, such as how a server was configured before hardening.
* Links to my own public repositories.

Before finishing a post, search it and the files next to it for IP addresses, hostnames, usernames, and paths.

## Writing Philosophy

Prefer:

**"Here is something useful I learned, how it works, and how to use it."**

Avoid:

**"Here is everything you need to know about this subject."**

Keep the scope intentionally narrow.

If a topic is large, cover only the part relevant to the lesson being shared rather than trying to explain the entire technology.

A reader should be able to finish most posts quickly and leave with one or two useful pieces of knowledge.

## Length

Keep posts short.

Do not add content simply to make an article feel complete or substantial.

Prefer a focused 500-1,000 word post over a 2,000-3,000 word comprehensive guide.

Shorter posts are acceptable when the topic does not require much explanation.

If a section is not necessary to understand or apply the main lesson, remove it.

Do not include sections merely because technical articles commonly contain them.

## Scope

Each post should generally answer a small number of questions:

* What did I learn?
* Why is it useful or relevant?
* How does it work?
* How can someone use or reproduce it?
* Is there anything important to be aware of?

Not every post needs to answer all five.

Stay focused on the specific lesson.

Do not expand into loosely related concepts unless they are necessary to understand the topic.

## Title

Use descriptive titles.

The title should tell the reader what they are going to learn.

Prefer:

`Using OIDC to Authenticate GitHub Actions with AWS`

`Kubernetes Network Policies: Restricting Traffic Between Pods`

`Running Terraform Without Long-Lived AWS Credentials`

Avoid exaggerated titles such as:

`The Ultimate Guide to Kubernetes Network Policies`

`Everything You Need to Know About Terraform`

`Master Kubernetes Security`

Do not describe a post as an "ultimate", "complete", or "comprehensive" guide unless it genuinely is one.

## Date

Put the date I wrote the post in italics on the line after the title:

```markdown
# Using OIDC to Authenticate GitHub Actions with AWS

*September 21, 2026*
```

Use the date of the commit that first added the post. If the post is not committed yet, use today's date.

## Opening

Start with the reason the post exists.

Usually one or two short paragraphs are enough.

Good openings explain:

* Something encountered while working
* A limitation or problem discovered
* A useful behavior that was not immediately obvious
* A technique worth remembering
* A solution that may help someone facing the same problem

It is acceptable to briefly use first person when it naturally explains why the post was written.

For example:

> While configuring GitHub Actions, I wanted to avoid storing long-lived AWS credentials as repository secrets. OIDC provides a way for GitHub Actions to request temporary credentials directly from AWS.

Keep this brief.

Do not turn the opening into a personal story.

Avoid generic introductions such as:

> In today's rapidly evolving cloud-native landscape, security has become more important than ever.

Begin with the actual topic.

## Paragraphs

Use short paragraphs.

Most paragraphs should contain one idea and one or two sentences.

A paragraph may occasionally contain three sentences when necessary.

Avoid large blocks of prose.

Prefer:

> The token is short-lived and generated for each workflow run. This removes the need to maintain permanent AWS access keys in GitHub.

Instead of expanding the same idea across several paragraphs.

## Tone

Write in a practical, calm, technical tone.

The writing should feel like knowledge being shared between engineers.

It can be slightly personal, but should not become conversational or diary-like.

First person is acceptable when describing something learned or encountered:

> I initially expected the configuration to apply globally, but the setting is namespace-specific.

Use first person only when it adds useful context.

Do not repeatedly write:

* "I think"
* "I feel"
* "In my opinion"
* "I personally prefer"

Technical explanations should normally remain direct and objective.

## Headings

Use headings to make the post easy to scan.

Keep the hierarchy shallow:

```markdown
# Title

Opening paragraphs

## Main Section

Content

## Main Section

### Optional Subsection

## Conclusion
```

Normally do not go deeper than `###`.

Not every article needs many sections.

A short post may only need:

```markdown
# Title

Opening

## How It Works

## Implementation

## Conclusion
```

Choose sections based on the topic rather than following a fixed template.

## Section Titles

Use descriptive section headings.

Prefer:

`## How It Works`

`## Creating the IAM Role`

`## Configuring GitHub Actions`

`## Verifying the Connection`

Avoid vague headings such as:

`## Getting Started`

`## Diving Deeper`

`## Some Important Things`

The reader should understand what a section contains from its heading alone.

## Code

Code is part of the explanation, not separate from it.

Introduce a command or configuration with a short sentence explaining what it does.

Example:

Create the namespace:

```bash
kubectl create namespace example
```

For longer commands, split arguments across lines:

```bash
some-command \
  --first-option=value \
  --second-option=value
```

Always use an appropriate language identifier for fenced code blocks:

* `bash`
* `yaml`
* `json`
* `hcl`
* `python`
* `go`
* `text`

Do not include large code blocks when only a few relevant lines are needed.

Show the minimum code necessary to communicate the lesson.

## Explaining Code

Use this pattern where appropriate:

**Explanation → code → important observation**

For example:

The role must trust GitHub's OIDC provider:

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "..."
  }
}
```

The conditions determine which repositories or branches are allowed to assume the role.

Do not explain every line when the meaning is obvious.

Focus explanations on the parts that matter to the lesson.

## Inline Code

Use inline code for literal technical values such as:

* `kubectl`
* `Deployment`
* `values.yaml`
* `AWS_REGION`
* `/etc/config`
* `443`
* `main.tf`

Do not use inline code merely as visual emphasis.

## Lists

Use lists when several related points are easier to scan than prose.

Keep them short.

Prefer:

* **Temporary credentials:** Credentials expire automatically.
* **No stored keys:** GitHub does not need permanent AWS access keys.
* **Scoped access:** IAM conditions can restrict which workflows can authenticate.

Avoid long paragraphs inside bullets.

If a list becomes large, reconsider whether all of the items are necessary.

## Implementation Steps

Use numbered steps only when the reader genuinely needs to perform actions in sequence.

Example:

```markdown
## Implementation

### Step 1: Create the IAM Provider

...

### Step 2: Create the Role

...

### Step 3: Configure the Workflow

...
```

Do not force every article into a step-by-step tutorial.

Some lessons are better explained with two or three normal sections.

## Background Information

Provide only the background necessary to understand the lesson.

Do not reproduce documentation that the reader can easily find elsewhere.

If understanding the topic requires knowing what a technology does, explain it in a few sentences and continue.

The post should add value through explanation, experience, examples, or practical context rather than by rewriting official documentation.

## Things Learned

When appropriate, highlight observations that were useful or surprising.

For example:

> One detail that is easy to miss is that the configuration is namespace-specific.

Or:

> The important part is the `sub` condition. Without it, repositories other than the intended one may be able to assume the role.

These observations are often more valuable than lengthy background sections.

Focus on details that someone implementing the same thing could easily overlook.

## Best Practices

Do not automatically add a "Best Practices" section.

Include recommendations only when they are directly relevant to the lesson.

Three useful recommendations are better than ten generic ones.

## Conclusion

Keep the conclusion very short.

One paragraph is usually enough.

Restate what was learned or why the technique is useful.

Example:

> Using OIDC removes the need to keep long-lived AWS credentials in GitHub. The setup requires a little more IAM configuration, but workflows can then request temporary credentials whenever they run.

Do not recap every section.

Do not introduce new information.

Do not add a generic call to action.

A conclusion may be omitted entirely when the article naturally ends after the final explanation.

## Avoid Filler

Remove phrases such as:

* "Let's dive in."
* "Without further ado."
* "In today's fast-paced world..."
* "As you can see..."
* "It's important to note that..." when the sentence can simply state the important fact
* "Now that we have X, let's move on to Y."
* "There you have it."
* "Hopefully this guide helped you..."

Use headings and direct statements instead.

## Editing Rule

When editing a post, ask:

**Does this sentence help someone understand the thing I learned?**

If not, remove it.

Prioritize:

1. Useful information
2. Clear explanation
3. Reproducible examples
4. Important details or gotchas

Do not prioritize article length.

The finished post should feel like a concise engineering note that was polished enough to share publicly.
