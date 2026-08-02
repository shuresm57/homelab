# Explanation

The two services will run in VM's on Proxmox. I literally only chose Proxmox, because I want to tinker with it and try it out.

## Local AI

Half a tool I need, half a tool that I know more and more companies use daily.

### What I need it for

I'd like to experiment with RAG to see how I can finetune the model to fit a behaviour and with a knowledge that can improve upon my knowledge. 

In the future I need it as API calls, that can be run whenever the future git server makes a PR. I want to make a highly specialized code reviever in the languages I know and use, and with the way I like to work. So not only to keep a high level of quality but also to keep a mean standard of code altogher.

### How it makes me better

I think that many more companies in the future will have local LLM's, than what we see now. Setting local LLM's up will be a sough after skill.


## Jellyfin

Literally just for my own media server, will actually also be setup with a TrueNAS VM for storage. Just for pure personal use :)

# Setup

I will use terraform to provision the Proxmox VMs, allocate ram, cpu and storage and for installation of ollama and jellyfin, I will use Ansible. This is to keep a level of IaC - also because it serves as form of documentation on the hardware and tech stack.

For the time being, no real networking rules will be applied. These two services do not have to speak to eachother.

# Deadline

End of August 2026.